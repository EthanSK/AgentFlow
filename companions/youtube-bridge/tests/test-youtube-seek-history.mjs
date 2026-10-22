import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../extension/seek-history.js', import.meta.url), 'utf8');
function model(initial = 30) {
  const context = vm.createContext({});
  vm.runInContext(source, context);
  return context.__voiceInkYouTubeSeekHistory.createHistory(initial);
}
const values = stack => [...stack];
const seek = (h, to) => { h.seeking(); h.seeked(to); };
const navigate = (h, direction, from) => {
  let target;
  assert.equal(h.navigate(direction, from, () => true, time => { target = time; }), true);
  h.seeking();
  h.seeked(target);
  return target;
};

test('normal playback, throttled timeupdates, pauses and speed changes add no history', () => {
  const h = model();
  for (const time of [31, 32, 80, 300, 300, 301]) h.sample(time);
  assert.deepEqual(values(h.state.undo), []);
  assert.equal(h.state.last, 301);
});
test('seeking retains the last stable position even when currentTime already changed', () => {
  const h = model();
  h.sample(120, true);
  h.seeking();
  h.sample(120, false); // queued timeupdate before seeked cannot erase origin
  h.seeked(120);
  assert.deepEqual(values(h.state.undo), [30]);
});
test('Undo and Redo can alternate without recording their own jumps', () => {
  const h = model();
  seek(h, 120);
  assert.equal(navigate(h, 'undo', 123), 30);
  assert.deepEqual(values(h.state.undo), []);
  assert.deepEqual(values(h.state.redo), [123]);
  assert.equal(navigate(h, 'redo', 31), 123);
  assert.equal(navigate(h, 'undo', 123), 31);
  assert.equal(navigate(h, 'redo', 31), 123);
});
test('multiple undo steps retain order and a new external seek clears Redo', () => {
  const h = model();
  seek(h, 100); seek(h, 200); seek(h, 300);
  assert.equal(navigate(h, 'undo', 300), 200);
  assert.equal(navigate(h, 'undo', 200), 100);
  seek(h, 450);
  assert.deepEqual(values(h.state.undo), [30, 100]);
  assert.deepEqual(values(h.state.redo), []);
});
test('one timeline drag coalesces several seeked events into one Undo', () => {
  const h = model();
  h.beginGesture(31);
  seek(h, 50); seek(h, 90); seek(h, 200);
  assert.deepEqual(values(h.state.undo), []);
  h.endGesture(200, false);
  assert.deepEqual(values(h.state.undo), [31]);
});
test('pointer release before seeked preserves the original drag position', () => {
  const h = model();
  h.beginGesture(31); h.seeking(); h.endGesture(200, true); h.seeked(200);
  assert.deepEqual(values(h.state.undo), [31]);
});
test('aborted or stationary drag creates no history', () => {
  const h = model();
  h.beginGesture(30); seek(h, 70); seek(h, 30); h.endGesture(30, false);
  assert.deepEqual(values(h.state.undo), []);
});
test('ongoing seeks and gestures reject duplicate Undo clicks', () => {
  const h = model(); seek(h, 100);
  h.navigate('undo', 100, () => true, () => {});
  assert.equal(h.navigate('undo', 100, () => true, () => {}), false);
  h.seeked(30); seek(h, 90); h.beginGesture(90);
  assert.equal(h.navigate('undo', 90, () => true, () => {}), false);
});
test('expired DVR positions and thrown seek writes preserve stacks', () => {
  const h = model(); seek(h, 100);
  assert.equal(h.navigate('undo', 100, () => false, () => assert.fail()), false);
  assert.equal(h.navigate('undo', 100, () => true, () => { throw new Error('unavailable'); }), false);
  assert.deepEqual(values(h.state.undo), [30]);
  assert.equal(h.state.pending, null);
});
test('an interrupted Undo does not consume the old target or create Redo', () => {
  const h = model(); seek(h, 100);
  h.navigate('undo', 100, () => true, () => {}); h.seeked(500);
  assert.deepEqual(values(h.state.undo), [30, 100]);
  assert.deepEqual(values(h.state.redo), []);
});
test('Undo to an already reached position completes without waiting for absent seek events', () => {
  const h = model(); seek(h, 100);
  assert.equal(h.navigate('undo', 30, () => true, () => assert.fail()), true);
  assert.equal(h.state.pending, null);
  assert.deepEqual(values(h.state.redo), [30]);
});
test('an aborted media load releases pending navigation without consuming history', () => {
  const h = model(); seek(h, 100);
  h.navigate('undo', 100, () => true, () => {}); h.cancelPending();
  assert.equal(h.state.pending, null);
  assert.deepEqual(values(h.state.undo), [30]);
});
test('new clips, emptied media and ads can reset all pending state', () => {
  const h = model(); seek(h, 100); h.beginGesture(100); h.seeking(); h.reset();
  assert.deepEqual(values(h.state.undo), []);
  assert.equal(h.state.last, null);
  assert.equal(h.state.pending, null);
  assert.equal(h.state.gesture, null);
  seek(h, 500); // initial restored position is not a seek back to zero
  assert.deepEqual(values(h.state.undo), []);
  h.sample(501); seek(h, 600);
  assert.deepEqual(values(h.state.undo), [501]);
});
test('history is bounded and rejects non-finite or insignificant positions', () => {
  const h = model(); seek(h, 30.1); seek(h, NaN); h.sample(30);
  for (let index = 1; index <= 100; index++) seek(h, 30 + index * 10);
  assert.equal(h.state.undo.length, 50);
  assert.equal(h.state.undo[0], 530);
  assert.equal(h.navigate('undo', Infinity, () => true, () => assert.fail()), false);
});
test('reinjection preserves only weakly keyed state and reloads the controller code', () => {
  const context = vm.createContext({}); vm.runInContext(source, context);
  const old = context.__voiceInkYouTubeSeekHistory;
  const video = {}; const history = old.createHistory(12);
  seek(history, 100); old.histories.set(video, { identity: 'a', history });
  vm.runInContext(source, context);
  assert.equal(context.__voiceInkYouTubeSeekHistory.histories, old.histories);
  assert.deepEqual(values(context.__voiceInkYouTubeSeekHistory.histories.get(video).history.state.undo), [12]);
});
test('manifest, reconnect injection and packaging all include the history module first', () => {
  const read = path => fs.readFileSync(new URL(path, import.meta.url), 'utf8');
  assert.deepEqual(JSON.parse(read('../extension/manifest.json')).content_scripts[0].js, ['seek-history.js', 'content-script.js']);
  assert.match(read('../extension/background.js'), /files: \['seek-history\.js', 'content-script\.js'\]/);
  assert.match(read('../scripts/package-extension.sh'), /seek-history\.js content-script\.js/);
  assert.match(read('../extension/content-script.js'), /seekHistory\?\.refresh\(video, currentVideoId\(\)\)/);
});
