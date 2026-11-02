// Native-host memory regression test.
//
// Guards the reader-thread autorelease-pool fix in readLoop(). That detached thread never returns to a
// run loop, so FileHandle.readData(ofLength:) used to strand two autoreleased 8 KB NSData buffers per
// Chrome message (~16 KB/message, all MALLOC_SMALL). A real host reached 4.3 GB after eight days.
//
// The test compiles an ISOLATED copy of the host exactly as scripts/build.sh does. The copy differs
// only in its distributed-notification names (moved to a per-run test namespace, so it can never reach
// or be commanded by a running menu-bar app) and its log path (a temp file instead of
// ~/Library/Logs). Each isolation rewrite must match exactly once or the test aborts before compiling.
// It then drives Chrome-framed youtube-state messages through stdin and bounds phys_footprint growth.
//
// usage: node tests/test-native-host-memory.mjs [sourceRoot]   (sourceRoot defaults to this repo)
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceRoot = path.resolve(process.argv[2] ?? repoRoot);
const HOST_SOURCE = 'native-host/AgentFlowBridgeNativeHost.swift';
const SHARED_SOURCE = 'shared/AgentFlowBridgeShared.swift';

const WARMUP_MESSAGES = 2_000;
const MEASURED_ROUNDS = 5;
const MESSAGES_PER_ROUND = 2_000;
// The leak retained ~16 KB/message (≈160 MB for these 10k messages). The fixed host's burst high-water
// is well under 1 KB/message. 24 MB separates the two by a wide margin either way.
const MAX_GROWTH_BYTES = 24 * 1024 * 1024;

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'native-host-memory-'));
const work = path.join(temporaryRoot, 'artifacts.noindex');
fs.mkdirSync(work);
let host;
try {
  const testNamespace = `test.nativeHostMemory.${process.pid}.${Date.now()}`;
  const logPath = path.join(work, 'host.log');
  const replaceOnce = (text, pattern, replacement, what) => {
    const matches = text.match(new RegExp(pattern.source, 'g')) ?? [];
    assert.equal(matches.length, 1, `isolation rewrite for ${what} must match exactly once`);
    return text.replace(pattern, replacement);
  };

  let shared = fs.readFileSync(path.join(sourceRoot, SHARED_SOURCE), 'utf8');
  const hostSource = fs.readFileSync(path.join(sourceRoot, HOST_SOURCE), 'utf8');
  shared = replaceOnce(shared, /(static let bridgeToApp = Notification\.Name\()"[^"]+"\)/,
    `$1"${testNamespace}.bridgeToApp")`, 'bridgeToApp');
  shared = replaceOnce(shared, /(static let appToBridge = Notification\.Name\()"[^"]+"\)/,
    `$1"${testNamespace}.appToBridge")`, 'appToBridge');
  shared = replaceOnce(shared, /private let logURL = [^\n]*(?:\n\s+\.[^\n]*)*/,
    'private let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NATIVE_HOST_MEMORY_TEST_LOG"]!)',
    'logURL');
  assert.doesNotMatch(shared, /homeDirectoryForCurrentUser/, 'isolated copy must not resolve the real log');
  fs.writeFileSync(path.join(work, 'Shared.swift'), shared);
  fs.writeFileSync(path.join(work, 'Host.swift'), hostSource);

  const binary = path.join(work, 'host');
  const build = spawnSync('swiftc', [
    path.join(work, 'Shared.swift'), path.join(work, 'Host.swift'), '-o', binary,
    '-framework', 'AppKit', '-framework', 'ApplicationServices',
  ], { encoding: 'utf8', timeout: 300_000 });
  assert.equal(build.status, 0, `swiftc failed:\n${build.stderr}`);

  host = spawn(binary, ['chrome-extension://native-host-memory-test/'], {
    stdio: ['pipe', 'pipe', 'ignore'],
    env: { NATIVE_HOST_MEMORY_TEST_LOG: logPath, HOME: work, CFFIXED_USER_HOME: work, PATH: '/usr/bin:/bin' },
  });

  // Native-messaging frames from the host. `host-status` only arrives from the 0.8 s fallback timer
  // armed by our `status-request`, which runs on the main queue after every earlier queued message,
  // so it is a barrier proving the host has fully processed everything sent before it.
  let pending = Buffer.alloc(0);
  const statusWaiters = [];
  host.stdout.on('data', (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 4) {
      const length = pending.readUInt32LE(0);
      if (pending.length < 4 + length) break;
      const message = JSON.parse(pending.subarray(4, 4 + length).toString('utf8'));
      pending = pending.subarray(4 + length);
      if (message.type === 'host-status') statusWaiters.shift()?.();
    }
  });
  const exited = new Promise((resolve) => host.once('exit', resolve));

  const frame = (message) => {
    const body = Buffer.from(JSON.stringify(message), 'utf8');
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length, 0);
    return Buffer.concat([header, body]);
  };
  let sequence = 0;
  const stateMessage = () => {
    sequence += 1;
    return frame({
      type: 'youtube-state', tabId: 1000 + (sequence % 7), playing: sequence % 3 !== 0, reason: 'heartbeat',
      title: `Synthetic regression video ${sequence}`, url: `https://www.youtube.com/watch?v=TEST${sequence}`,
      currentTime: sequence % 900, duration: 1800, lastPlayedAt: 1_793_211_900_000 + sequence,
    });
  };
  const send = (buffer) => new Promise((resolve, reject) => {
    host.stdin.write(buffer, (error) => (error ? reject(error) : resolve()));
  });
  const barrier = async () => {
    const drained = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('host never drained its main queue')), 120_000);
      statusWaiters.push(() => { clearTimeout(timer); resolve(); });
    });
    await send(frame({ type: 'status-request' }));
    await drained;
  };
  // Measure the kernel's phys_footprint (what Activity Monitor reports), NOT RSS: the leaked buffers
  // are mostly-zero pages that are never touched again, so macOS compresses them out of RSS almost
  // immediately. The eight-day host showed 4.3 GB of footprint but only ~10 MB resident, and an RSS
  // assertion passes against the leaking code.
  const footprintBytes = () => {
    const sample = spawnSync('/usr/bin/footprint', ['-p', String(host.pid), '-f', 'bytes', '--noCategories'],
      { encoding: 'utf8', timeout: 60_000 });
    const match = /phys_footprint:\s+(\d+)\s+B/.exec(sample.stdout ?? '');
    assert.ok(sample.status === 0 && match, `could not sample host footprint:\n${sample.stderr}`);
    return Number(match[1]);
  };
  const sendRound = (count) => send(Buffer.concat(Array.from({ length: count }, stateMessage)));

  // Warm-up absorbs one-time setup (notification-center connection, decoder metadata, malloc regions).
  await sendRound(WARMUP_MESSAGES);
  await barrier();
  const before = footprintBytes();
  for (let round = 0; round < MEASURED_ROUNDS; round += 1) {
    await sendRound(MESSAGES_PER_ROUND);
    await barrier();
  }
  const after = footprintBytes();
  const growth = after - before;
  const measured = MEASURED_ROUNDS * MESSAGES_PER_ROUND;
  console.log(`native host phys_footprint ${(before / 1048576).toFixed(1)} MB -> ${(after / 1048576).toFixed(1)} MB `
    + `over ${measured} messages (${(growth / measured).toFixed(0)} B/message)`);
  assert.ok(growth < MAX_GROWTH_BYTES,
    `native host retained ${(growth / 1048576).toFixed(1)} MB across ${measured} Chrome messages; `
    + 'readLoop() must drain an autorelease pool per message');

  host.stdin.end(); // EOF is Chrome's disconnect: the host must exit cleanly.
  assert.equal(await exited, 0, 'host should exit 0 on stdin EOF');
  host = undefined;
  console.log('native host memory regression test passed');
} finally {
  if (host) host.kill('SIGKILL');
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
