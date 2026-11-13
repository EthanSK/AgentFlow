import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const read = file => fs.readFileSync(new URL(`${process.env.TEST_EXTENSION_DIR || '../extension'}/${file}`, import.meta.url), 'utf8');
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
function setup(stored = {}, initialUrl = 'https://video.example/watch') {
  const runtimeMessages = event(), nativeMessages = event(), commands = [], injections = [], nativeReplies = [];
  let url = initialUrl;
  let liveDocument = 'embed-document';
  let playing = true;
  let playBlocked = false;
  let queryDelay = null;
  let clockOffset = 0;
  const clock = class extends Date { static now() { return Date.now() + clockOffset; } };
  const chrome = {
    runtime: { id: 'extension', getURL: p => `chrome-extension://extension/${p}`,
      onMessage: runtimeMessages, onInstalled: event(), onStartup: event(),
      connectNative: () => ({ onMessage: nativeMessages, onDisconnect: event(), postMessage: message => nativeReplies.push(message) }) },
    storage: { local: { get: async keys => Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map(k => [k, structuredClone(stored[k])])),
      set: async value => Object.assign(stored, structuredClone(value)), remove: async key => { delete stored[key]; } } },
    windows: { getLastFocused: async () => ({ id: 1 }), onRemoved: event() },
    alarms: { create() {}, clear: async () => true, onAlarm: event() },
    scripting: { executeScript: async request => { injections.push(request); return []; } },
    tabs: {
      onRemoved: event(), onActivated: event(), onReplaced: event(), onUpdated: event(),
      query: async () => {
        if (queryDelay) await queryDelay();
        return [{ id: 7, url, windowId: 1, active: true, audible: playing }];
      },
      get: async () => ({ id: 7, url, windowId: 1, active: true, audible: playing }),
      sendMessage(id, message, options, callback) {
        if (typeof options === 'function') { callback = options; options = undefined; }
        if (message.type === 'state-request') { callback?.({ ok: true }); return; }
        commands.push({ id, message, options });
        if (message.type === 'generic-video-command') {
          if (options?.documentId !== liveDocument) {
            chrome.runtime.lastError = { message: 'Document is gone' }; callback?.(); delete chrome.runtime.lastError; return;
          }
          const pause = ['pause-youtube', 'explicit-pause-video'].includes(message.command);
          const play = ['resume-youtube', 'explicit-play-video'].includes(message.command);
          const paused = pause && playing;
          const resumed = play && !playing && !playBlocked;
          if (paused) playing = false;
          if (resumed) playing = true;
          callback?.({ ok: true, paused, resumed, reason: paused || resumed ? 'changed' :
            play ? (playBlocked ? 'play-blocked' : 'already-playing') : 'not-playing',
            sought: message.command === 'seek-youtube', speedHeld: message.command !== 'end-youtube-speed-hold' });
        } else {
          const paused = message.type === 'explicit-pause-video' && playing;
          const resumed = message.type === 'explicit-play-video' && !playing;
          if (paused) playing = false;
          if (resumed) playing = true;
          callback?.({ ok: true, paused, resumed: resumed || message.type === 'resume-youtube',
            reason: paused || resumed ? 'changed' : message.type === 'explicit-pause-video' ? 'not-playing' : 'already-playing' });
        }
      },
    },
  };
  let context;
  context = vm.createContext({ chrome, console: { debug() {}, warn() {} }, Date: clock, Map, Set, Promise, URL,
    // Accelerate only the browser deadline, preserving retry/backoff semantics in other fixtures.
    setTimeout: (fn, ms) => setTimeout(fn, ms === 2000 ? 5 : ms), clearTimeout,
    importScripts: (...files) => files.forEach(file => vm.runInContext(read(file), context)),
  });
  vm.runInContext(read('background.js'), context);
  const run = expression => vm.runInContext(expression, context);
  const sender = { id: 'extension', tab: { id: 7, title: 'Synthetic video', url }, frameId: 14, documentId: liveDocument, url: 'https://embed.example/player' };
  const report = (message, senderOverride = {}) => runtimeMessages.listeners[0](message, { ...sender, ...senderOverride }, () => {});
  report({ type: 'generic-video-state', instanceId: 'embed-instance', mediaId: 'exact-video', playing: true, area: 200000 });
  return { stored, run, commands, injections, report, chrome, nativeReplies,
    native: message => nativeMessages.listeners[0](message),
    blockPlay: () => { playBlocked = true; },
    delayQuery: fn => { queryDelay = fn; },
    advanceClock: milliseconds => { clockOffset += milliseconds; },
    start: () => run("enqueueDictationOp('fixture-start', () => pauseYouTubeForDictation('fixture'))"),
    stop: () => run("enqueueDictationOp('fixture-stop', () => resumeYouTubeForDictation('fixture'))"),
    finish: () => run("enqueueDictationOp('fixture-finish', () => finishDictationPreservingPlayback('fixture'))"),
    navigate: () => { url = 'https://www.youtube.com/watch?v=different'; liveDocument = 'replacement-document';
      chrome.tabs.onUpdated.listeners.forEach(fn => fn(7, { url }, { url })); },
  };
}

const explicit = setup();
const request = (fixture, action, number, issuedAt = Date.now()) => {
  const requestId = `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
  fixture.native({ type: 'hellochat-video-command', requestId, videoAction: action, issuedAt });
  return requestId;
};
const replies = fixture => fixture.nativeReplies.filter(message => message.type === 'hellochat-video-result');
const directions = fixture => fixture.commands.filter(command => (command.message.command ?? command.message.type).startsWith('explicit-'));
const idle = fixture => fixture.run('dictationOpChain');
const statusId = '00000000-0000-4000-8000-000000000000';
explicit.native({ type: 'hellochat-video-status-request', requestId: statusId, issuedAt: Date.now() });
assert.equal(explicit.nativeReplies.find(message => message.requestId === statusId)?.protocolVersion, 1);
assert.equal(directions(explicit).length, 0, 'status must leave playback alone');
request(explicit, 'pause', 1);
request(explicit, 'pause', 1);
request(explicit, 'pause', 2);
request(explicit, 'play', 3);
request(explicit, 'play', 4);
await idle(explicit);
assert.deepEqual(replies(explicit).map(({ changed, reason }) => [changed, reason]), [
  [true, 'paused'], [false, 'already-paused'], [true, 'played'], [false, 'already-playing'],
]);
assert.ok(directions(explicit).every(command => command.options?.documentId === 'embed-document'));
assert.equal(explicit.run('dictationDepth'), 0);
assert.equal(explicit.run('dictationPausedTabId'), null);
console.log('PASS H Chat status, explicit generic directions and duplicate request handling');

const youtubeCommands = setup({}, 'https://www.youtube.com/watch?v=test');
request(youtubeCommands, 'pause', 1);
request(youtubeCommands, 'play', 2);
await idle(youtubeCommands);
assert.deepEqual(directions(youtubeCommands).map(command => command.message.type), ['explicit-pause-video', 'explicit-play-video']);
assert.deepEqual(replies(youtubeCommands).map(({ reason }) => reason), ['paused', 'played']);
console.log('PASS H Chat explicit commands select the YouTube adapter on a YouTube tab');

const recording = setup();
await recording.start();
request(recording, 'pause', 1);
await idle(recording);
await recording.stop();
assert.equal(replies(recording)[0]?.reason, 'already-paused');
assert.ok(!recording.commands.some(command => command.message.command === 'resume-youtube'));
const rejected = setup();
request(rejected, 'pause', 1, Date.now() - 3000);
await idle(rejected);
assert.equal(replies(rejected)[0]?.reason, 'stale-request');
assert.equal(directions(rejected).length, 0);

const delayed = setup();
delayed.delayQuery(() => delayed.advanceClock(2600));
request(delayed, 'pause', 1);
await idle(delayed);
assert.equal(replies(delayed)[0]?.reason, 'stale-request');
assert.equal(directions(delayed).length, 0, 'discovery cannot renew the deadline');

const blocked = setup();
request(blocked, 'pause', 1);
await idle(blocked);
blocked.blockPlay();
request(blocked, 'play', 2);
await idle(blocked);
assert.equal(replies(blocked).at(-1)?.reason, 'play-blocked');
console.log('PASS H Chat preserves explicit pause during recording and reports expired or blocked commands');
const basic = setup(); await basic.start(); await basic.stop();
assert.deepEqual(basic.commands.filter(c => c.message.type === 'generic-video-command').map(c => c.message.command), ['pause-youtube', 'resume-youtube']);
assert.ok(basic.commands.every(c => c.options?.documentId === 'embed-document'));
assert.equal(basic.run('dictationDepth'), 0);
console.log('PASS actual background recording pipeline pauses/resumes one exact generic embedded document');

const overlap = setup(); await overlap.start(); await overlap.start(); await overlap.stop();
assert.equal(overlap.commands.filter(c => c.message.command === 'resume-youtube').length, 0);
await overlap.stop(); assert.equal(overlap.commands.filter(c => c.message.command === 'resume-youtube').length, 1);
console.log('PASS overlapping recordings keep the generic target paused until final stop');

const preserving = setup(); await preserving.start(); await preserving.finish();
assert.equal(preserving.commands.filter(c => c.message.command === 'resume-youtube').length, 0);
const takeover = setup(); await takeover.start();
takeover.report({ type: 'generic-video-manual-control', instanceId: 'embed-instance', mediaId: 'exact-video', action: 'pause', contentTimestamp: Date.now() + 5 });
await takeover.stop(); assert.equal(takeover.commands.filter(c => c.message.command === 'resume-youtube').length, 0);
console.log('PASS playback-preserving finish and manual control never resume generic videos');

const navigation = setup(); await navigation.start(); navigation.navigate();
// Do not wait through the old YouTube retry ladder in this deterministic guard.
const result = await navigation.run("sendDirectionalWithReinject(7, 'resume-youtube')");
assert.equal(result.delivered, false);
assert.equal(navigation.commands.at(-1).message.type, 'generic-video-command');
assert.equal(navigation.commands.at(-1).options.documentId, 'embed-document');
assert.equal(navigation.commands.filter(c => c.message.type === 'resume-youtube').length, 0);
console.log('PASS generic-to-YouTube navigation cannot reinterpret old ownership as a new YouTube resume');

const asleep = setup(); await asleep.start();
const woke = setup(structuredClone(asleep.stored)); await woke.stop();
assert.equal(woke.commands.find(c => c.message.command === 'resume-youtube')?.options.documentId, 'embed-document');
const scrub = setup(); await scrub.run("beginYouTubeSpeedHold('fixture-hold', 2, 2500)");
const count = scrub.injections.length;
await scrub.run('seekYouTubeFiveSeconds(5)'); await scrub.run("endYouTubeSpeedHold('fixture-hold', 2, 2500, 'release')");
assert.equal(scrub.injections.length, count, 'healthy scrub and release must not reinject');
assert.deepEqual(scrub.commands.filter(c => c.message.type === 'generic-video-command').map(c => c.message.command), ['begin-youtube-speed-hold', 'seek-youtube', 'end-youtube-speed-hold']);
console.log('PASS actual worker sleep, native speed-hold routing, scrub and release preserve target identity');

const youtube = setup({}, 'https://www.youtube.com/watch?v=different');
youtube.report({ type: 'generic-video-state', instanceId: 'ad-frame', mediaId: 'ad-video', playing: true, area: 900000 },
  { tab: { id: 7, url: 'https://www.youtube.com/watch?v=different', title: 'YouTube fixture' } });
assert.equal(youtube.run('genericVideoRouter.aggregate(7)'), null);
assert.equal(await youtube.run('usesGenericVideo(7)'), false);
await youtube.run("sendAgenticMouseOneShotWithReinject(7, { type: 'seek-youtube', seekSeconds: 5 })");
assert.equal(youtube.commands.at(-1).message.type, 'seek-youtube');
assert.equal(youtube.commands.filter(c => c.message.type === 'generic-video-command').length, 0);
assert.ok(youtube.injections.every(request => !request.files.includes('generic-video.js')));
console.log('PASS a generic embedded frame cannot steal a top-level YouTube command or trigger reinjection');

const completes = async operation => {
  let timer;
  try {
    return await Promise.race([operation, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('recording queue stranded by unresolved browser request')), 150);
    })]);
  } finally { clearTimeout(timer); }
};
const never = () => new Promise(() => {});

for (const phase of ['generic-injection', 'generic-message', 'youtube-injection', 'youtube-message', 'tabs-query', 'tab-read', 'window-read', 'storage-read']) {
  const h = setup({}, phase.startsWith('youtube') ? 'https://www.youtube.com/watch?v=fixture' : undefined);
  // Let independent startup hydration/discovery finish before faulting one recording request.
  await new Promise(resolve => setTimeout(resolve, 0));
  const restore = { injection: h.chrome.scripting.executeScript, message: h.chrome.tabs.sendMessage,
    query: h.chrome.tabs.query, get: h.chrome.tabs.get, window: h.chrome.windows.getLastFocused, storage: h.chrome.storage.local.get };
  if (phase.endsWith('injection')) {
    if (phase.startsWith('generic')) h.run('genericVideoRouter.navigated(7)');
    h.chrome.scripting.executeScript = never;
  } else if (phase.endsWith('message')) h.chrome.tabs.sendMessage = () => {};
  else if (phase === 'tabs-query') h.chrome.tabs.query = never;
  else if (phase === 'tab-read') h.chrome.tabs.get = never;
  else if (phase === 'window-read') h.chrome.windows.getLastFocused = never;
  else h.chrome.storage.local.get = never;
  await completes(h.start());
  h.chrome.scripting.executeScript = restore.injection; h.chrome.tabs.sendMessage = restore.message;
  h.chrome.tabs.query = restore.query; h.chrome.tabs.get = restore.get;
  h.chrome.windows.getLastFocused = restore.window; h.chrome.storage.local.get = restore.storage;
  await completes(h.finish());
  h.report({ type: 'generic-video-state', instanceId: 'embed-instance', mediaId: 'exact-video', playing: true, area: 200000 });
  await completes(h.start()); await completes(h.finish());
  assert.equal(h.run('dictationDepth'), 0);
  console.log(`PASS ${phase} timeout releases the serial queue for subsequent recordings`);
}

const ordinary = setup(); await new Promise(resolve => setTimeout(resolve, 0));
ordinary.run('genericVideoRouter.navigated(7); tabPlayState.clear()');
ordinary.stored.tabPlayState = {};
ordinary.chrome.tabs.query = async () => Array.from({ length: 100 }, (_, i) => ({ id: i + 10, url: 'https://text.example/', windowId: 1, active: false, audible: false }));
ordinary.commands.length = 0; ordinary.injections.length = 0;
await completes(ordinary.start()); await completes(ordinary.finish());
assert.equal(ordinary.commands.length, 0); assert.equal(ordinary.injections.length, 0);
console.log('PASS ordinary text tabs are not injected/scanned as fallback video candidates');

const superseded = setup({}, 'https://www.youtube.com/watch?v=fixture');
await new Promise(resolve => setTimeout(resolve, 0));
superseded.chrome.scripting.executeScript = async () => { superseded.run('pendingPauseCommandCount = 1'); return []; };
await completes(superseded.run("resumeTabWithConfirmation(7, dictationSessionToken, 'fixture')"));
assert.equal(superseded.commands.filter(c => c.message.type === 'resume-youtube').length, 0);
console.log('PASS a new recording during injection prevents stale resume actuation');
