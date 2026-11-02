// Exercise the real shared logger against isolated files, including damaged UTF-8 and concurrent writers.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-flow-log-'));
const work = path.join(temporaryRoot, 'artifacts.noindex');
fs.mkdirSync(work);
try {
  const source = fs.readFileSync(path.join(root, 'shared/AgentFlowBridgeShared.swift'), 'utf8');
  const pattern = /private let logURL = [^\n]*(?:\n\s+\.[^\n]*)*/;
  assert.equal(source.match(new RegExp(pattern.source, 'g'))?.length, 1);
  const isolated = source.replace(pattern,
    'private let logURL = URL(fileURLWithPath: CommandLine.arguments[1])');
  assert.doesNotMatch(isolated, /homeDirectoryForCurrentUser/);
  fs.writeFileSync(path.join(work, 'Shared.swift'), isolated);
  fs.writeFileSync(path.join(work, 'Main.swift'), `
import Foundation
@main enum Check {
  static func main() {
    if CommandLine.arguments.count > 2 {
      for index in 0..<1000 { autoreleasepool { log("writer=\\(CommandLine.arguments[2]) entry=\\(index) →") } }
    } else { pruneLog() }
  }
}
`);
  const binary = path.join(work, 'check');
  const built = spawnSync('swiftc', [path.join(work, 'Shared.swift'), path.join(work, 'Main.swift'), '-o', binary], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.stderr);
  const log = path.join(work, 'test.log');
  const old = '2020-01-01T00:00:00.000Z [test] old\n';
  const recent = `${new Date().toISOString()} [test] recent\n`;
  const prune = (contents) => {
    fs.writeFileSync(log, contents);
    const run = spawnSync(binary, [log], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    return fs.readFileSync(log);
  };
  const damagedRecent = Buffer.concat([Buffer.from(recent.trimEnd()), Buffer.from([0x86, 0x92, 10])]);
  assert.deepEqual(prune(Buffer.concat([Buffer.from(old), damagedRecent])), damagedRecent);
  assert.equal(prune(old + recent.trimEnd()).toString(), recent);
  assert.equal(prune(old).length, 0);
  const legacy = Array.from({ length: 4005 }, (_, index) => `legacy ${index}\n`).join('');
  const retained = prune(legacy).toString().trimEnd().split('\n');
  assert.equal(retained.length, 2999); // The existing 3000-entry tail includes the empty entry after the final newline.
  assert.equal(retained[0], 'legacy 1006');
  assert.equal(prune(recent + '\n' + recent).toString(), recent + recent);
  fs.writeFileSync(log, recent);
  const unchanged = fs.statSync(log).mtimeMs;
  assert.equal(spawnSync(binary, [log]).status, 0);
  assert.equal(fs.statSync(log).mtimeMs, unchanged);
  console.log('PASS retention, damaged UTF-8, newline rules, legacy tail and no-op preservation');

  fs.writeFileSync(log, '');
  await Promise.all(Array.from({ length: 4 }, (_, writer) => new Promise((resolve, reject) => {
    const child = spawn(binary, [log, String(writer)], { stdio: 'ignore' });
    child.on('error', reject);
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`writer exit ${code}`)));
  })));
  const lines = fs.readFileSync(log, 'utf8').trimEnd().split('\n');
  assert.equal(lines.length, 4000);
  const records = lines.map((line) => line.match(/writer=\d entry=\d+ →$/)?.[0]);
  assert.ok(records.every((record) => record !== undefined), 'every record must retain its complete UTF-8 marker');
  assert.equal(new Set(records).size, 4000);
  console.log('PASS 4000 complete UTF-8 records from four concurrent logger processes');
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
