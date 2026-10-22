import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../extension/background.js', import.meta.url), 'utf8');
const extensionId = 'test-voiceink-extension';
const popup = { id: extensionId, url: `chrome-extension://${extensionId}/status.html` };
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });

function worker(stored = {}, options = {}) {
  const commands = [];
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
    scripting: { executeScript: async () => [] },
    windows: { onRemoved: event(), getLastFocused: async () => ({ id: 1 }) },
    tabs: {
      onRemoved: event(), onActivated: event(), onReplaced: event(), onUpdated: event(),
      query: async () => [{ id: 7, windowId: 1, active: true, audible: playing, url: 'https://www.youtube.com/watch?v=fixture' }, { id: 8, windowId: 1, active: false, audible: false, url: 'https://www.youtube.com/watch?v=other' }],
      get: async () => ({ id: 7, windowId: 1, active: true, audible: playing }),
      sendMessage: (id, message, callback) => {
        let result = { playing };
        if (message.type === 'jump-ahead-youtube') {
          commands.push({ id, type: message.type });
          result = { jumpAheadClicked: options.visible === true, reason: options.visible ? undefined : 'jump-ahead-not-visible' };
        } else if (message.type === 'pause-youtube') {
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
    stored, commands, native, run,
    failWrite: () => { failWrite = true; },
    message: (enabled, sender = popup) => new Promise(resolve => runtimeMessages.listeners[0]({ type: 'set-voiceink-auto-pause', enabled }, sender, resolve)),
    start: () => run("enqueueDictationOp('test-start', () => pauseYouTubeForDictation('fixture'))"),
    stop: () => run("enqueueDictationOp('test-stop', () => resumeYouTubeForDictation('fixture'))"),
    finish: () => run("enqueueDictationOp('test-finish', () => finishDictationPreservingPlayback('fixture'))"),
    idle: () => run('dictationDepth === 0 && dictationPausedTabId === null'),
  };
}

for (const visible of [false, true]) {
  const h = worker({}, { visible });
  await h.run('jumpAheadYouTube()');
  assert.equal(h.commands.length, 1);
  assert.equal(h.commands[0].id, 7);
  assert.equal(h.commands[0].type, 'jump-ahead-youtube');
  const result = h.native.findLast(m => m.type === 'youtube-jump-ahead-result');
  assert.equal(result.jumpAheadClicked, visible);
  assert.equal(result.tabId, 7);
  assert.equal(h.idle(), true);
}
console.log('Jump ahead stays on one selected target and preserves dictation ownership');
