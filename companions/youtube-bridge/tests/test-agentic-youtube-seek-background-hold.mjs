import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../extension/background.js', import.meta.url), 'utf8');
const event = () => ({ addListener() {} });
const nativeMessages = [];
let injected = 0;
let speedHeld = true;
let receiverAvailable = true;
let seekCount = 0;

const chrome = {
  runtime: {
    id: 'test-voiceink-extension',
    lastError: undefined,
    getURL: (path) => `chrome-extension://test-voiceink-extension/${path}`,
    onMessage: event(), onInstalled: event(), onStartup: event(),
    connectNative: () => ({
      onMessage: event(), onDisconnect: event(),
      postMessage: (message) => nativeMessages.push(message),
    }),
  },
  storage: { local: {
    get: async () => ({}),
    set: async () => {},
  } },
  alarms: { create() {}, clear: async () => true, onAlarm: event() },
  scripting: { executeScript: async () => {
    injected += 1;
    // Injecting content-script.js runs the old script's cleanup, restoring 1×.
    speedHeld = false;
    receiverAvailable = true;
    return [];
  } },
  windows: { onRemoved: event(), getLastFocused: async () => ({ id: 1 }) },
  tabs: {
    onRemoved: event(), onActivated: event(), onReplaced: event(), onUpdated: event(),
    query: async () => [{
      id: 7, windowId: 1, active: true, audible: true,
      url: 'https://www.youtube.com/watch?v=fixture',
    }],
    get: async () => ({ id: 7, windowId: 1, active: true, audible: true }),
    sendMessage: (_id, message, callback) => {
      if (!receiverAvailable) {
        chrome.runtime.lastError = { message: 'Receiving end does not exist' };
        callback?.();
        chrome.runtime.lastError = undefined;
        return;
      }
      if (message.type === 'seek-youtube') seekCount += 1;
      callback?.({ sought: message.type === 'seek-youtube' });
    },
  },
};

const context = vm.createContext({
  chrome, console: { debug() {}, warn() {} }, Date, Map, Set, Promise, URL,
  setTimeout, clearTimeout, importScripts() {},
  createChromeTabHistoryController: () => ({
    initialize: async () => {}, removed() {}, activated() {}, replaced() {}, windowRemoved() {},
  }),
  createChromeWebsiteOpener: () => ({}),
});
vm.runInContext(source, context, { filename: 'background.js' });
// Let the service worker's intentional startup injection settle before measuring a scrub.
await new Promise((resolve) => setTimeout(resolve, 0));
injected = 0;
speedHeld = true;

await vm.runInContext('seekYouTubeFiveSeconds(5)', context);
assert.equal(seekCount, 1);
assert.equal(injected, 0, 'a healthy seek must not re-inject and end an active speed hold');
assert.equal(speedHeld, true);
assert.equal(nativeMessages.findLast((message) => message.type === 'youtube-seek-result')?.sought, true);

receiverAvailable = false;
await vm.runInContext('seekYouTubeFiveSeconds(-5)', context);
assert.equal(injected, 1, 'a missing receiver still gets one recovery injection');
assert.equal(seekCount, 2);
assert.equal(nativeMessages.findLast((message) => message.type === 'youtube-seek-result')?.sought, true);

console.log('Healthy YouTube scrub keeps the speed hold; missing receiver recovers once');
