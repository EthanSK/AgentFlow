import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('../extension/content-script.js', import.meta.url),
  'utf8',
);

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.paused = false;
    this.ended = false;
    this.playbackRate = 1.25;
    this.currentTime = 30;
    this.duration = 120;
  }

  play() {
    this.paused = false;
    return Promise.resolve();
  }

  pause() {
    this.paused = true;
  }
}

const video = new FakeVideo();
const buttons = [];
const player = { querySelectorAll: () => buttons };
video.closest = () => player;
const button = (label = 'Jump ahead') => ({
  textContent: label, disabled: false, hidden: false, 'aria-disabled': null, parentElement: null, clicks: 0,
  style: { display: 'block', visibility: 'visible', opacity: '1' },
  rect: { width: 100, height: 40, top: 10, left: 10, bottom: 50, right: 110 },
  getAttribute(name) { return this[name] ?? null; },
  getBoundingClientRect() { return this.rect; },
  click() { this.clicks++; },
});
let runtimeListener;
let cleanup;
const context = vm.createContext({
  console,
  getComputedStyle: node => node.style,
  Date,
  URL,
  Promise,
  EventTarget,
  HTMLVideoElement: FakeVideo,
  MutationObserver: class {
    observe() {}
    disconnect() {}
  },
  document: {
    title: 'Test video',
    documentElement: {},
    pictureInPictureElement: null,
    querySelector: () => video,
  },
  location: { href: 'https://www.youtube.com/watch?v=test', pathname: '/watch' },
  setTimeout,
  clearTimeout,
  window: {
    innerWidth: 1280, innerHeight: 720,
    setInterval: () => 1,
    clearInterval: () => {},
  },
  chrome: {
    runtime: {
      lastError: undefined,
      sendMessage: (_message, callback) => callback?.(),
      onMessage: {
        addListener: (listener) => { runtimeListener = listener; },
        removeListener: () => {},
      },
    },
  },
});
Object.defineProperty(context, '__youtubeSpotifyMediaKeyBridgeCleanup', {
  get: () => cleanup,
  set: (value) => { cleanup = value; },
  configurable: true,
});

vm.runInContext(source, context, { filename: 'content-script.js' });
assert.equal(typeof runtimeListener, 'function');
assert.equal(typeof cleanup, 'function');

const send = (type, token = 'hold-token', restorePlaybackRate) => {
  let response;
  runtimeListener({
    type,
    holdToken: token,
    playbackRate: 2,
    holdLeaseMilliseconds: 2_500,
    restorePlaybackRate,
  }, null, (value) => { response = value; });
  return response;
};


const jump = () => send('jump-ahead-youtube');
assert.equal(jump().jumpAheadClicked, false);
const target = button();
buttons.push(target);
assert.equal(jump().jumpAheadClicked, true);
assert.equal(target.clicks, 1);
assert.equal(video.currentTime, 30);
assert.equal(video.playbackRate, 1.25);
assert.equal(video.paused, false);
for (const mutate of [
  () => target.disabled = true,
  () => target['aria-disabled'] = 'true',
  () => target.hidden = true,
  () => target.style.opacity = '0',
  () => target.style.display = 'none',
  () => target.style.visibility = 'hidden',
  () => target.rect.width = 0,
  () => target.rect.top = 900,
  () => target.parentElement = { hidden: true, style: target.style, getAttribute: () => null },
]) {
  Object.assign(target, button());
  mutate();
  assert.equal(jump().jumpAheadClicked, false);
  assert.equal(target.clicks, 0);
}
Object.assign(target, button('Skip ad'));
assert.equal(jump().jumpAheadClicked, false);
Object.assign(target, button());
buttons.push(button());
assert.equal(jump().reason, 'ambiguous-jump-ahead');
assert.equal(target.clicks, 0);
buttons.pop();
context.location.pathname = '/shorts/test';
assert.equal(jump().jumpAheadClicked, false);
cleanup();
console.log('Jump ahead visibility, ambiguity, Shorts and playback preservation passed');
