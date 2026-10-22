import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const source = fs.readFileSync(new URL('../extension/generic-rate-bridge.js', import.meta.url), 'utf8');
class CustomEvent extends Event { constructor(type, options = {}) { super(type, options); this.detail = options.detail; } }
class Video extends EventTarget { constructor() { super(); this.isConnected = true; this.playbackRate = 1.5; } }
function fixture({youtube = false, embedded = false, vsc = false} = {}) {
  const window = new EventTarget(); window.top = embedded ? {} : window;
  const video = new Video(), other = new Video();
  const state = {temporary: false, savedSpeed: 1.5, writes: [], indicators: []};
  if (vsc) video.vsc = {};
  const context = vm.createContext({window, location: {hostname: youtube ? 'www.youtube.com' : 'example.test'},
    HTMLVideoElement: Video, CustomEvent, JSON, Number,
    VSC: {IntentClassifier: {VERDICTS: {TEMPORARY_OVERRIDE: 'temporary'}}},
    VSC_controller: {actionHandler: {
      writeRate(v, rate) { state.writes.push([v, rate]); v.playbackRate = rate; },
      syncIndicator(v, rate) { state.indicators.push([v, rate]); },
    }, eventManager: {arbitration: {
      onExternalRate(v, event, verdict) { assert.equal(v, video); assert.equal(verdict, 'temporary'); state.temporary = true; },
      completeTemporaryOverride(v) { assert.equal(v, video); state.temporary = false; },
    }}},
  });
  vm.runInContext(source, context);
  let index = 0;
  const write = (phase, rate, target = video) => {
    const id = `request-${++index}`;
    let response = null;
    const listener = event => { response = JSON.parse(event.detail); };
    target.addEventListener('voiceink-video-rate-response', listener);
    const request = new CustomEvent('voiceink-video-rate-request', {detail: JSON.stringify({id, phase, rate})});
    request.composedPath = () => [target, window];
    window.dispatchEvent(request);
    target.removeEventListener('voiceink-video-rate-response', listener);
    return response;
  };
  return {context, state, video, other, write};
}
test('plain exact-video hold and restore never touch a second player', () => {
  const f = fixture();
  assert.equal(f.write('hold', 2).ok, true); assert.equal(f.video.playbackRate, 2);
  assert.equal(f.other.playbackRate, 1.5);
  assert.equal(f.write('restore', 1.5).ok, true); assert.equal(f.video.playbackRate, 1.5);
});
test('VSC temporary cooperation preserves saved speed through renew, seek and release', () => {
  const f = fixture({vsc: true});
  assert.equal(f.write('hold', 2).ok, true);
  assert.equal(f.state.temporary, true); assert.equal(f.state.savedSpeed, 1.5);
  // VSC lifecycle events leave an explicitly temporary override alone.
  if (!f.state.temporary) f.video.playbackRate = f.state.savedSpeed;
  assert.equal(f.video.playbackRate, 2);
  assert.equal(f.write('hold', 2).ok, true);
  assert.equal(f.write('restore', 1.5).ok, true);
  assert.equal(f.state.temporary, false); assert.equal(f.state.savedSpeed, 1.5);
  assert.equal(f.other.playbackRate, 1.5);
  assert.ok(f.state.writes.every(([target]) => target === f.video));
});
test('unknown VSC APIs reject a hold instead of persisting or fighting speed', () => {
  const f = fixture({vsc: true}); f.context.VSC_controller = {};
  assert.equal(f.write('hold', 2).reason, 'incompatible-speed-controller');
  assert.equal(f.video.playbackRate, 1.5);
});
test('controller errors roll back a partly applied hold', () => {
  const f = fixture({vsc: true});
  f.context.VSC_controller.eventManager.arbitration.onExternalRate = () => { throw new Error('fixture'); };
  assert.equal(f.write('hold', 2).reason, 'media-control-failed');
  assert.equal(f.video.playbackRate, 1.5);
});
test('reinjecting the adapter adds no second writer and invalid requests never mutate media', () => {
  const f = fixture({vsc: true}); vm.runInContext(source, f.context);
  assert.equal(f.write('hold', 2).ok, true); assert.equal(f.state.writes.length, 1);
  assert.equal(f.write('hold', 8), null); assert.equal(f.video.playbackRate, 2);
  f.video.isConnected = false; assert.equal(f.write('restore', 1.5), null);
});
test('top-level YouTube keeps its original adapter while an embed can cooperate', () => {
  assert.equal(fixture({youtube: true}).write('hold', 2), null);
  assert.equal(fixture({youtube: true, embedded: true}).write('hold', 2).ok, true);
});
test('the extension packages and injects the main-world adapter before generic discovery', () => {
  const router = fs.readFileSync(new URL('../extension/generic-video-router.js', import.meta.url), 'utf8');
  assert.ok(router.indexOf("files: ['generic-rate-bridge.js']") < router.indexOf("files: ['generic-video.js']"));
  const packageSource = fs.readFileSync(new URL('../scripts/package-extension.sh', import.meta.url), 'utf8');
  assert.ok(packageSource.includes('generic-rate-bridge.js'));
});
