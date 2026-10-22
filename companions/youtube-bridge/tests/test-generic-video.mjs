import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const content = fs.readFileSync(new URL('../extension/generic-video.js', import.meta.url), 'utf8');
const routerSource = fs.readFileSync(new URL('../extension/generic-video-router.js', import.meta.url), 'utf8');
class CustomEvent extends Event { constructor(type, options = {}) { super(type, options); this.detail = options.detail; } }
class Video extends EventTarget {
  constructor(area = 200000, muted = false) {
    super(); Object.assign(this, { area, muted, paused: false, ended: false, isConnected: true,
      playbackRate: 1.25, volume: .5, currentTime: 30, duration: 120, currentSrc: 'clip-one', hidden: false });
    this.seekable = { length: 1, start: () => 0, end: () => 120 };
  }
  getBoundingClientRect() { return { left: 0, top: 0, right: this.area / 400, bottom: 400 }; }
  pause() { this.paused = true; this.dispatchEvent(new Event('pause')); }
  play() { this.paused = false; this.dispatchEvent(new Event('play')); return Promise.resolve(); }
}
function page(videos, { shadow = null, host = 'example.test', embedded = false } = {}) {
  let listener, nextId = 0;
  const reports = [], timers = new Map();
  const document = new EventTarget();
  Object.assign(document, { pictureInPictureElement: null, querySelectorAll: selector => selector === 'video' ? videos : shadow ? [{ shadowRoot: shadow }] : [] });
  const window = new EventTarget(); window.top = embedded ? {} : window;
  const chrome = { runtime: { id: 'extension', getManifest: () => ({}), sendMessage: (m, callback) => { reports.push(m); callback?.(); },
    onMessage: { addListener: fn => { listener = fn; }, removeListener: () => {} } } };
  const context = vm.createContext({ document, window, location: { hostname: host }, chrome, navigator: { userActivation: { isActive: false } },
    HTMLVideoElement: Video, CustomEvent, getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }),
    innerWidth: 2000, innerHeight: 1500, crypto: { randomUUID: () => `id-${++nextId}` },
    MutationObserver: class { observe() {} disconnect() {} }, queueMicrotask, Promise, Date, Map, WeakMap, Set,
    setTimeout: fn => { const id = ++nextId; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id),
    setInterval: () => 100, clearInterval() {}, console });
  vm.runInContext(content, context);
  const selected = () => reports.findLast(m => m.type === 'generic-video-state');
  let pauseTarget = null;
  const send = (command, overrides = {}) => new Promise(resolve => {
    const state = command === 'resume-youtube' || command === 'pause-youtube' && pauseTarget ? pauseTarget : selected();
    if (command === 'pause-youtube' && !pauseTarget) pauseTarget = state;
    listener({ type: 'generic-video-command', instanceId: state.instanceId, mediaId: state.mediaId,
      command, holdToken: 'hold', playbackRate: 2, holdLeaseMilliseconds: 2500, ...overrides }, { id: 'extension' }, resolve);
  });
  return { context, document, reports, selected, send, listener: () => listener, expire: () => [...timers.values()].forEach(fn => fn()) };
}

const preview = new Video(10000, true), main = new Video();
const p = page([preview, main]);
assert.equal((await p.send('begin-youtube-speed-hold')).speedHeld, true);
assert.equal(main.playbackRate, 2); assert.equal(preview.playbackRate, 1.25);
await p.send('seek-youtube', { seekSeconds: 5 }); assert.equal(main.currentTime, 35); assert.equal(main.playbackRate, 2);
await p.send('adjust-youtube-volume', { volumeDelta: .05 }); assert.equal(main.volume, .55);
await p.send('end-youtube-speed-hold'); assert.equal(main.playbackRate, 1.25);
await p.send('begin-youtube-speed-hold'); p.expire(); assert.equal(main.playbackRate, 1.25);
await p.send('begin-youtube-speed-hold'); await p.send('end-youtube-speed-hold', { restorePlaybackRate: 1 }); assert.equal(main.playbackRate, 1);
console.log('PASS generic hold, scrub, volume, sticky reset and lost-release lease preserve exact player');

const rejectedVideo = new Video(), rejected = page([rejectedVideo]);
rejectedVideo.addEventListener('voiceink-video-rate-request', event => {
  const request = JSON.parse(event.detail);
  rejectedVideo.dispatchEvent(new CustomEvent('voiceink-video-rate-response', {
    detail: JSON.stringify({id: request.id, ok: false, reason: 'incompatible-speed-controller'}),
  }));
});
assert.equal((await rejected.send('begin-youtube-speed-hold')).reason, 'incompatible-speed-controller');
assert.equal(rejectedVideo.playbackRate, 1.25, 'an explicit page-helper rejection must never fall through to a direct setter');

const renewedVideo = new Video(), renewed = page([renewedVideo]);
let holdWrites = 0;
renewedVideo.addEventListener('voiceink-video-rate-request', event => {
  const request = JSON.parse(event.detail);
  const reject = request.phase === 'hold' && ++holdWrites > 1;
  if (!reject) renewedVideo.playbackRate = request.rate;
  renewedVideo.dispatchEvent(new CustomEvent('voiceink-video-rate-response', {
    detail: JSON.stringify({id: request.id, ok: !reject, reason: reject ? 'media-control-failed' : ''}),
  }));
});
assert.equal((await renewed.send('begin-youtube-speed-hold')).speedHeld, true);
assert.equal((await renewed.send('renew-youtube-speed-hold')).speedHeld, false);
assert.equal(renewedVideo.playbackRate, 1.25, 'a failed renewal must restore its prior rate before clearing ownership');
console.log('PASS rejected rate cooperation never bypasses the controller and a failed renewal restores the exact prior rate');

assert.equal((await p.send('pause-youtube')).paused, true);
assert.equal((await p.send('pause-youtube')).reason, 'not-playing');
assert.equal((await p.send('resume-youtube')).resumed, true);
await p.send('pause-youtube'); main.currentSrc = 'clip-two';
assert.equal((await p.send('resume-youtube')).reason, 'pause-ownership-lost'); assert.equal(main.paused, true);
main.play(); await p.send('pause-youtube'); p.context.navigator.userActivation.isActive = true;
main.play(); main.pause();
assert.equal((await p.send('resume-youtube')).reason, 'pause-ownership-lost');
assert.equal(main.paused, true);
console.log('PASS pause/resume ownership rejects source changes and manual play/pause');

const disconnected = page([new Video()]);
await disconnected.send('pause-youtube'); disconnected.context.document.querySelectorAll('video')[0].isConnected = false;
assert.equal((await disconnected.send('resume-youtube')).reason, 'player-changed');
assert.equal((await p.send('begin-youtube-speed-hold', { playbackRate: 8 })).reason, 'invalid-media-command');
assert.equal((await p.send('begin-youtube-speed-hold', { instanceId: 'other-document' })).reason, 'document-changed');
console.log('PASS detached video, stale document and malformed commands fail closed');
const expiredVideo = new Video(), expiredPage = page([expiredVideo]);
assert.equal((await expiredPage.send('pause-youtube', { expiresAt: Date.now() - 1 })).reason, 'playback-command-expired');
assert.equal(expiredVideo.paused, false, 'a frozen renderer must reject a pause delivered after its deadline');
await expiredPage.send('pause-youtube');
assert.equal((await expiredPage.send('resume-youtube', { expiresAt: Date.now() - 1 })).reason, 'playback-command-expired');
assert.equal(expiredVideo.paused, true, 'an expired resume must not start playback');
console.log('PASS delayed generic pause/resume messages expire before playback mutation');

const pip = new Video(1000); const other = new Video(); const pp = page([other, pip]);
pp.document.pictureInPictureElement = pip; pp.context.__voiceInkGenericVideoBridge.report('state-request');
await pp.send('begin-youtube-speed-hold'); assert.equal(pip.playbackRate, 2); assert.equal(other.playbackRate, 1.25);
vm.runInContext(content, pp.context); assert.equal(pip.playbackRate, 2, 'healthy reinjection must preserve hold');
pp.context.__voiceInkGenericVideoBridge.dispose(); assert.equal(pip.playbackRate, 1.25);
assert.equal(page([new Video()], { host: 'www.youtube.com' }).listener(), undefined);
assert.equal(typeof page([new Video()], { host: 'www.youtube.com', embedded: true }).listener(), 'function');
const shadow = new EventTarget(); const shadowVideo = new Video(); shadow.querySelectorAll = s => s === 'video' ? [shadowVideo] : [];
const sp = page([], { shadow }); await sp.send('begin-youtube-speed-hold'); assert.equal(shadowVideo.playbackRate, 2);
console.log('PASS Picture-in-Picture, idempotent discovery, open shadow roots and YouTube embeds');

const stored = {}, commands = [], injected = [];
let documentExists = true;
const chrome = { runtime: { id: 'extension' }, storage: { local: {
  get: async key => ({ [key]: structuredClone(stored[key]) }), set: async values => Object.assign(stored, structuredClone(values)) } },
  scripting: { executeScript: async request => { injected.push(request); } }, tabs: {
    sendMessage(tabId, m, options, callback) {
      commands.push({ tabId, m, options });
      if (!documentExists) { chrome.runtime.lastError = { message: 'document gone' }; callback(); delete chrome.runtime.lastError; return; }
      callback({ ok: true, paused: m.command === 'pause-youtube', resumed: m.command === 'resume-youtube', speedHeld: m.command.includes('speed-hold') && m.command !== 'end-youtube-speed-hold' });
    } } };
const worker = vm.createContext({ chrome, console, Date, Map, Object, Number, Promise, setTimeout, clearTimeout }); vm.runInContext(routerSource, worker);
const makeRouter = () => vm.runInContext('createGenericVideoRouter(chrome)', worker);
const r = makeRouter();
const sender = (frameId, documentId) => ({ id: 'extension', tab: { id: 7, title: 'Synthetic fixture', url: 'https://example.test/' }, frameId, documentId, url: 'https://embed.test/video' });
r.accept({ instanceId: 'root', mediaId: 'root-video', playing: false, area: 5000 }, sender(0, 'root-doc'));
r.accept({ instanceId: 'embed', mediaId: 'embed-video', playing: true, area: 100000 }, sender(12, 'embed-doc'));
assert.equal((await r.send(7, { type: 'pause-youtube' })).response.paused, true);
assert.equal(commands.at(-1).options.documentId, 'embed-doc');
r.accept({ instanceId: 'new', mediaId: 'new-video', playing: true, interactedAt: Date.now() }, sender(12, 'new-doc'));
const asleep = makeRouter(); await asleep.send(7, { type: 'resume-youtube' });
assert.equal(await asleep.owns(7), true);
assert.equal(commands.at(-1).options.documentId, 'embed-doc');
assert.equal(commands.at(-1).m.mediaId, 'embed-video'); assert.equal(injected.length, 0);
documentExists = false;
asleep.navigated(7);
assert.equal(await asleep.owns(7), true, 'navigation retains owned document rather than choosing the new page adapter');
assert.equal((await asleep.send(7, { type: 'resume-youtube' })).delivered, false);
assert.equal(injected.length, 0, 'owned resume must never discover another frame');
await asleep.clearPause();
assert.equal((await asleep.send(7, { type: 'resume-youtube' })).response.reason, 'media-ownership-lost');
documentExists = true;
await r.send(7, { type: 'begin-youtube-speed-hold', holdToken: 'exact-hold' });
const speedWorker = makeRouter(); await speedWorker.send(7, { type: 'end-youtube-speed-hold', holdToken: 'exact-hold' });
assert.equal(commands.at(-1).options.documentId, 'new-doc');
assert.equal(r.accept({ instanceId: 'attack', mediaId: 'attack-video', playing: true }, { ...sender(0, 'root-doc'), id: 'other-extension' }), null);
console.log('PASS frame/document/media identity survives worker sleep and rejects navigation without fallback');

const manifest = JSON.parse(fs.readFileSync(new URL('../extension/manifest.json', import.meta.url), 'utf8'));
assert.deepEqual(manifest.host_permissions, ['http://*/*', 'https://*/*']);
assert.ok(manifest.content_scripts.find(s => s.js.includes('generic-video.js')).all_frames);
assert.equal(manifest.content_scripts.find(s => s.js.includes('generic-rate-bridge.js')).world, 'MAIN');
assert.ok(manifest.content_scripts.find(s => s.js.includes('generic-rate-bridge.js')).all_frames);
assert.ok(manifest.content_scripts.find(s => s.js.includes('content-script.js')).matches.every(s => s.includes('youtube.com')));
console.log('PASS broad web access keeps the top-level YouTube adapter and excludes restricted browser pages');
