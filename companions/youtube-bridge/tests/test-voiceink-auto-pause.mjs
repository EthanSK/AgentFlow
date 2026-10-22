import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../extension/background.js', import.meta.url), 'utf8');
const extensionId = 'test-voiceink-extension';
const popup = { id: extensionId, url: `chrome-extension://${extensionId}/status.html` };
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });

function worker(stored = {}, options = {}) {
  const commands = [];
  const injections = [];
  let missedFirstPause = false;
  const native = [];
  let playing = true;
  let failWrite = false;
  const runtimeMessages = event();
  const nativeMessages = event();
  const chrome = {
    runtime: {
      id: extensionId, getURL: (path) => `chrome-extension://${extensionId}/${path}`,
      onMessage: runtimeMessages, onInstalled: event(), onStartup: event(),
      connectNative: () => ({ onMessage: nativeMessages, onDisconnect: event(), postMessage: (m) => native.push(m) }),
    },
    storage: { local: {
      get: async (keys) => {
        if (options.failRead) throw new Error('storage unavailable');
        return structuredClone(Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map(k => [k, stored[k]])));
      },
      set: (values) => {
        if (failWrite && 'voiceInkAutoPauseEnabled' in values) return Promise.reject(new Error('quota'));
        Object.assign(stored, structuredClone(values));
        return Promise.resolve();
      },
    } },
    alarms: { create() {}, clear: async () => true, onAlarm: event() },
    scripting: { executeScript: async (request) => { injections.push(request); return []; } },
    windows: { onRemoved: event(), getLastFocused: async () => ({ id: 1 }) },
    tabs: {
      onRemoved: event(), onActivated: event(), onReplaced: event(), onUpdated: event(),
      query: async () => [{ id: 7, windowId: 1, active: true, audible: playing, url: 'https://www.youtube.com/watch?v=fixture' }],
      get: async () => ({ id: 7, windowId: 1, active: true, audible: playing }),
      sendMessage: (id, message, callback) => {
        if (message.type === 'pause-youtube' && options.missingFirstPause && !missedFirstPause) {
          missedFirstPause = true;
          chrome.runtime.lastError = { message: 'Could not establish connection. Receiving end does not exist.' };
          callback?.();
          delete chrome.runtime.lastError;
          return Promise.resolve();
        }
        let result = { playing };
        if (message.type === 'pause-youtube') {
          commands.push(message.type);
          result = { paused: playing, reason: playing ? 'paused' : 'not-playing' };
          playing = false;
        } else if (message.type === 'resume-youtube') {
          commands.push(message.type);
          result = { resumed: !playing, reason: playing ? 'already-playing' : 'resumed' };
          playing = true;
        } else if (message.type === 'seek-youtube') {
          commands.push(message.type);
          result = { sought: true };
        }
        callback?.(result);
        return Promise.resolve(result);
      },
    },
  };
  const context = vm.createContext({
    chrome, console: { debug() {}, warn() {} }, Date, Map, Set, Promise, URL,
    setTimeout, clearTimeout, importScripts() {},
    createChromeTabHistoryController: () => ({ initialize: async () => {}, removed() {}, activated() {}, replaced() {}, windowRemoved() {} }),
    createChromeWebsiteOpener: () => ({}),
  });
  vm.runInContext(source, context);
  const run = (code) => vm.runInContext(code, context);
  return {
    stored, commands, injections, native, run,
    failWrite: () => { failWrite = true; },
    message: (enabled, sender = popup) => new Promise(resolve => runtimeMessages.listeners[0]({ type: 'set-voiceink-auto-pause', enabled }, sender, resolve)),
    start: () => run("enqueueDictationOp('test-start', () => pauseYouTubeForDictation('fixture'))"),
    stop: () => run("enqueueDictationOp('test-stop', () => resumeYouTubeForDictation('fixture'))"),
    finish: () => run("enqueueDictationOp('test-finish', () => finishDictationPreservingPlayback('fixture'))"),
    idle: () => run('dictationDepth === 0 && dictationPausedTabId === null'),
  };
}

const basic = worker();
await basic.start();
await basic.stop();
assert.deepEqual(basic.commands, ['pause-youtube', 'resume-youtube']);
assert.equal(basic.idle(), true);
console.log('PASS default-on keeps normal pause/resume');

basic.commands.length = 0;
assert.equal((await basic.message(false)).ok, true);
await basic.start();
await basic.stop();
assert.deepEqual(basic.commands, []);
assert.equal(basic.idle(), true);
assert.equal(basic.stored.voiceInkAutoPauseEnabled, false);
console.log('PASS off persists and balances recording without playback');

const slept = worker(structuredClone(basic.stored));
await slept.start();
await slept.stop();
assert.deepEqual(slept.commands, []);
console.log('PASS worker restart honors saved off setting');

const active = worker();
await active.start();
active.commands.length = 0;
await active.message(false);
await active.message(true);
await active.start();
await active.stop();
assert.deepEqual(active.commands, []);
assert.equal(active.run('dictationDepth'), 1);
const rehydrated = worker(structuredClone(active.stored));
await rehydrated.stop();
assert.deepEqual(rehydrated.commands, []);
assert.equal(rehydrated.idle(), true);
await rehydrated.start();
await rehydrated.stop();
assert.deepEqual(rehydrated.commands, ['pause-youtube', 'resume-youtube']);
console.log('PASS off/on mid-recording relinquishes through overlap and worker restart');

const initiallyOff = worker({ voiceInkAutoPauseEnabled: false });
await initiallyOff.start();
await initiallyOff.message(true);
await initiallyOff.stop();
assert.deepEqual(initiallyOff.commands, []);
await initiallyOff.start();
await initiallyOff.finish();
assert.deepEqual(initiallyOff.commands, ['pause-youtube']);
assert.equal(initiallyOff.idle(), true);
console.log('PASS enabling waits for fresh recording; preserving finish never plays');

const rejected = worker();
for (const [enabled, sender] of [[false, { id: extensionId, url: 'https://www.youtube.com/' }], ['false', popup], [false, { ...popup, id: 'other' }]]) {
  assert.equal((await rejected.message(enabled, sender)).ok, false);
}
assert.equal(rejected.stored.voiceInkAutoPauseEnabled, undefined);
rejected.failWrite();
assert.equal((await rejected.message(false)).ok, false);
await rejected.start();
await rejected.stop();
assert.deepEqual(rejected.commands, ['pause-youtube', 'resume-youtube']);
console.log('PASS malformed/untrusted requests and failed writes preserve preference');

const unreadable = worker({}, { failRead: true });
await unreadable.start();
await unreadable.stop();
assert.deepEqual(unreadable.commands, []);
console.log('PASS unavailable storage cannot silently enable playback automation');

const queued = worker();
const pending = [queued.start(), queued.message(false), queued.stop(), queued.message(true)];
await Promise.all(pending);
assert.deepEqual(queued.commands, ['pause-youtube']);
assert.equal(queued.idle(), true);
console.log('PASS setting writes serialize with in-flight recording edges');

const mouse = worker({ voiceInkAutoPauseEnabled: false });
await mouse.run("loadAutoPausePreference()");
await mouse.run('seekYouTubeFiveSeconds(-5)');
assert.deepEqual(mouse.commands, ['seek-youtube']);
console.log('PASS Agentic Mouse seek stays independent of automatic pausing');

const manual = worker();
await manual.start();
manual.commands.length = 0;
manual.run("handleManualPlaybackControl(7, 'play', Date.now())");
await manual.run('dictationOpChain');
await manual.stop();
assert.deepEqual(manual.commands, []);
console.log('PASS manual playback takeover still prevents auto-resume');

const fastPause = worker();
await new Promise(resolve => setImmediate(resolve));
fastPause.injections.length = 0;
await fastPause.start();
assert.deepEqual(fastPause.commands, ['pause-youtube']);
assert.equal(fastPause.injections.length, 0, 'healthy player pauses without reinjection');
await fastPause.stop();
console.log('PASS healthy recording pause uses existing listener immediately');

const recoveredPause = worker({}, { missingFirstPause: true });
await new Promise(resolve => setImmediate(resolve));
recoveredPause.injections.length = 0;
await recoveredPause.start();
assert.deepEqual(recoveredPause.commands, ['pause-youtube']);
assert.equal(recoveredPause.injections.length, 1, 'missing listener is reinjected once');
await recoveredPause.stop();
assert.deepEqual(recoveredPause.commands, ['pause-youtube', 'resume-youtube']);
assert.equal(recoveredPause.idle(), true);
console.log('PASS missing pause listener retains one reinjection and same-tab recovery');
