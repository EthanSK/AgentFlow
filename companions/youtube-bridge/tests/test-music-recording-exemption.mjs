import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../extension/content-script.js', import.meta.url), 'utf8');
class Video extends EventTarget {
  paused = false; ended = false; playbackRate = 1; currentTime = 30; duration = 120;
  plays = 0; pauses = 0;
  play() { this.plays++; this.paused = false; this.dispatchEvent(new Event('play')); return Promise.resolve(); }
  pause() { this.pauses++; this.paused = true; this.dispatchEvent(new Event('pause')); }
}
function fixture({ title = 'An ordinary tutorial', playlist = '', playlistId = 'mix', hidden = false,
  metadataId = 'fixture', documentTitle = 'An ordinary tutorial', metadata = true, paused = false,
  url = 'https://www.youtube.com/watch?v=fixture&list=mix' } = {}) {
  const video = new Video(); video.paused = paused;
  let listener;
  const headers = playlist ? [{ textContent: playlist, getAttribute: () => `/playlist?list=${playlistId}`,
    closest: () => hidden ? {} : null }] : [];
  const metadataNodes = metadata ? [{ getAttribute: () => metadataId, closest: () => hidden ? {} : null,
    querySelector: () => ({ textContent: title }) }] : [];
  const document = { title: documentTitle, documentElement: {}, pictureInPictureElement: null,
    querySelector: () => video,
    querySelectorAll: selector => selector === 'ytd-watch-metadata' ? metadataNodes : headers };
  vm.runInNewContext(source, {
    console: { debug() {}, warn() {} }, Date, Event, EventTarget, HTMLVideoElement: Video,
    MutationObserver: class { observe() {} disconnect() {} }, Promise, URL, clearTimeout, setTimeout,
    document, location: { href: url }, navigator: { userActivation: { isActive: false } },
    window: { clearInterval() {}, setInterval: () => 1 },
    chrome: { runtime: { sendMessage: (_m, cb) => cb?.(), onMessage: {
      addListener: value => { listener = value; }, removeListener() {} } } },
  });
  return { video, send: (type, respectMusicTitle = true) => new Promise(resolve => listener({ type, respectMusicTitle }, null, resolve)) };
}
for (const config of [
  { title: 'Mario Kart Wii Music' },
  { title: 'MUSIC: ambient' },
  { title: 'Ambient (music)' },
  { playlist: 'My music playlist' },
  { title: 'music', playlist: 'music' },
  { metadata: false, documentTitle: 'Shorts Music - YouTube', url: 'https://www.youtube.com/shorts/fixture' },
  { metadataId: 'retained-watch', title: 'Old tutorial', documentTitle: 'Shorts Music - YouTube', url: 'https://www.youtube.com/shorts/fixture' },
]) {
  for (const paused of [false, true]) {
    const f = fixture({ ...config, paused });
    assert.equal((await f.send('pause-youtube')).reason, 'music-title-exempt');
    assert.equal(f.video.paused, paused);
    assert.equal(f.video.plays + f.video.pauses, 0, 'recording start must not mutate music');
  }
}
console.log('PASS video OR playlist titles, casing, punctuation and Shorts; playing/paused music stays untouched');
for (const config of [
  { title: 'A musical performance' },
  { title: 'Musicology class' },
  { title: 'Nonmusic example' },
  { playlist: 'Music playlist', playlistId: 'old-list' },
  { title: 'Music', hidden: true },
  { metadataId: 'stale', title: 'Music', documentTitle: 'Music' },
  { documentTitle: 'Music recommendation', title: 'The current tutorial' },
  { playlist: 'Music', url: 'https://www.youtube.com/watch?v=fixture' },
]) {
  const f = fixture(config);
  assert.equal((await f.send('pause-youtube')).paused, true);
  assert.equal(f.video.paused, true);
  assert.equal((await f.send('resume-youtube')).resumed, true);
  assert.equal(f.video.paused, false);
}
console.log('PASS whole-word and current-page scoping; ordinary playback pause/resume preserved');
const manual = fixture({ title: 'Music' });
await manual.send('toggle-youtube');
assert.equal(manual.video.paused, true);
await manual.send('toggle-youtube');
assert.equal(manual.video.paused, false);
console.log('PASS explicit manual play/pause still controls music');

const legacy = fixture({ title: 'Music' });
assert.equal((await legacy.send('pause-youtube', false)).paused, true);
assert.equal((await legacy.send('resume-youtube', false)).resumed, true);
assert.equal(legacy.video.paused, false);
console.log('PASS old worker plus new page code keeps its original balanced pause/resume contract');
