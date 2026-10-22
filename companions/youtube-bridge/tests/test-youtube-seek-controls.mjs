import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../extension/seek-history.js', import.meta.url), 'utf8');

function setup({ paused = false, scale = 1 } = {}) {
  const eventTargets = [];
  class Target {
    listeners = new Map();
    constructor() { eventTargets.push(this); }
    addEventListener(name, callback) {
      if (!this.listeners.has(name)) this.listeners.set(name, new Set());
      this.listeners.get(name).add(callback);
    }
    removeEventListener(name, callback) { this.listeners.get(name)?.delete(callback); }
    emit(name, extra = {}) {
      const event = { target: this, composedPath: () => [this], stopPropagation() {}, ...extra };
      for (const callback of this.listeners.get(name) || []) callback(event);
    }
  }
  class Element extends Target {
    attributes = new Set(); style = {}; disabled = false; children = []; connected = true;
    hiddenWrites = 0; _hidden = false;
    get hidden() { return this._hidden; }
    set hidden(value) { this.hiddenWrites++; this._hidden = value; }
    classList = { contains: name => this.attributes.has(name) };
    setAttribute(name) { this.attributes.add(name); }
    toggleAttribute(name, enabled) { enabled ? this.attributes.add(name) : this.attributes.delete(name); }
    matches() { return false; }
    append(child) { this.children.push(child); child.parent = this; }
    querySelectorAll() { return this.children.filter(child => child.attributes.has('data-voiceink-seek-controls')); }
    remove() { this.connected = false; this.parent.children = this.parent.children.filter(child => child !== this); }
    getBoundingClientRect() { return { left: 0, top: 0, width: 220 * scale, height: 30 * scale, right: 220 * scale, bottom: 30 * scale }; }
    attachShadow() {
      const undo = new Element(); const redo = new Element(); redo._hidden = true;
      return this.shadowRoot = { innerHTML: '', activeElement: null, getElementById: id => id === 'undo' ? undo : redo };
    }
  }
  const player = new Element(); player.offsetWidth = 1000;
  player.getBoundingClientRect = () => ({ left: 0, top: 0, width: 1000 * scale, height: 560 * scale });
  const speed = new Element();
  let speedWidth = 60;
  speed.getBoundingClientRect = () => ({ left: 15 * scale, top: 20 * scale, right: (15 + speedWidth) * scale, bottom: 50 * scale, width: speedWidth * scale, height: 30 * scale });
  player.querySelector = () => ({ shadowRoot: { querySelector: () => speed } });
  const video = new Target();
  Object.assign(video, { currentTime: 30, readyState: 4, seeking: false, paused, isConnected: true,
    seekable: { length: 1, start: () => 0, end: () => 1000 },
    closest: () => player, getClientRects: () => [{}],
    play: () => assert.fail('Seek controls must never play'),
    pause: () => assert.fail('Seek controls must never pause'),
  });
  const document = new Target(); document.createElement = () => new Element();
  const window = new Target();
  const observers = []; const resizers = []; const frames = new Map(); let nextFrame = 0;
  const location = { href: 'https://www.youtube.com/watch?v=clip-a' };
  const context = vm.createContext({ URL, location, document, window, queueMicrotask,
    MutationObserver: class {
      constructor(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
      observe() {} disconnect() { this.disconnected = true; }
    },
    ResizeObserver: class {
      constructor(callback) { this.callback = callback; this.disconnected = false; resizers.push(this); }
      observe() {} unobserve() {} disconnect() { this.disconnected = true; }
    },
    requestAnimationFrame: callback => { frames.set(++nextFrame, callback); return nextFrame; },
    cancelAnimationFrame: id => frames.delete(id),
  });
  vm.runInContext(source, context);
  const api = context.__voiceInkYouTubeSeekHistory;
  const controller = api.createController(); controller.refresh(video, 'clip-a');
  const host = () => player.children[0];
  const button = name => host().shadowRoot.getElementById(name);
  const flushLayout = () => { const pending = [...frames.values()]; frames.clear(); pending.forEach(callback => callback()); };
  const seek = time => { video.currentTime = time; video.seeking = true; video.emit('seeking'); video.seeking = false; video.emit('timeupdate'); video.emit('seeked'); };
  const settle = () => { video.seeking = true; video.emit('seeking'); video.seeking = false; video.emit('seeked'); };
  return { api, controller, player, video, document, window, location, observers, resizers,
    frames, eventTargets, host, button, flushLayout, seek, settle, history: () => api.histories.get(video).history,
    setSpeedWidth: width => { speedWidth = width; resizers.at(-1).callback(); },
  };
}

for (const paused of [false, true]) {
  test(`overlay Undo and Redo preserve ${paused ? 'paused' : 'playing'} state`, () => {
    const h = setup({ paused });
    assert.equal(h.button('undo').disabled, true);
    assert.equal(h.button('redo').hidden, true);
    h.seek(150);
    assert.equal(h.button('undo').disabled, false);
    h.button('undo').emit('click');
    assert.equal(h.video.currentTime, 30);
    assert.equal(h.button('undo').disabled, true);
    h.settle();
    assert.equal(h.button('redo').hidden, false);
    h.button('redo').emit('click'); h.settle();
    assert.equal(h.video.currentTime, 150);
    assert.equal(h.video.paused, paused);
    assert.equal(h.button('redo').hidden, true);
  });
}
test('overlay appears only over the player or while its own button has focus', () => {
  const h = setup();
  assert.equal(h.host().attributes.has('data-visible'), false);
  h.player.emit('pointerenter');
  assert.equal(h.host().attributes.has('data-visible'), true);
  h.player.emit('pointerleave');
  assert.equal(h.host().attributes.has('data-visible'), false);
  h.host().shadowRoot.activeElement = h.button('undo'); h.host().emit('focusin');
  assert.equal(h.host().attributes.has('data-visible'), true);
});
test('compact translucent icons retain accessible names and distinct directions', () => {
  const h = setup();
  const markup = h.host().shadowRoot.innerHTML;
  assert.match(markup, /width:28px; height:28px/);
  assert.match(markup, /background:rgba\(20,20,20,\.25\)/);
  assert.match(markup, /opacity:\.65/);
  assert.match(markup, /#redo svg \{ transform:scaleX\(-1\); \}/);
  for (const [id, label] of [['undo', 'Undo last position'], ['redo', 'Redo']]) {
    const button = markup.match(new RegExp(`<button[^>]+id="${id}"[^>]*>([\\s\\S]*?)<\\/button>`));
    assert.ok(button);
    assert.ok(button[0].includes(`aria-label="${label}"`));
    assert.ok(button[0].includes(`title="${label}"`));
    assert.match(button[1], /<svg[^>]+aria-hidden="true"[^>]+focusable="false"/);
    assert.equal(button[1].replace(/<[^>]+>/g, '').trim(), '');
  }
});
test('buttons sit beside VSC, track its expansion, and fit below when space runs out', () => {
  const h = setup(); h.flushLayout();
  assert.equal(h.host().style.left, '83px');
  assert.equal(h.host().style.top, '20px');
  h.setSpeedWidth(250); h.flushLayout();
  assert.equal(h.host().style.left, '273px');
  h.setSpeedWidth(850); h.flushLayout();
  assert.equal(h.host().style.left, '15px');
  assert.equal(h.host().style.top, '58px');
});
test('collision layout converts scaled player rectangles back to CSS coordinates', () => {
  const h = setup({ scale: 0.8 }); h.flushLayout();
  assert.equal(h.host().style.left, '85px');
  assert.equal(h.host().style.top, '20px');
});
test('timeline drag coalesces and document pointerup finalizes it', () => {
  const h = setup();
  h.player.emit('pointerdown', { target: { closest: () => ({}) } });
  h.seek(60); h.seek(90); h.seek(150);
  assert.deepEqual([...h.history().state.undo], []);
  h.document.emit('pointerup');
  assert.deepEqual([...h.history().state.undo], [30]);
});
for (const release of ['pointerup', 'mouseup', 'pointercancel']) {
  test(`window ${release} releases a YouTube-captured timeline drag`, () => {
    const h = setup();
    h.player.emit('pointerdown', { target: { closest: () => ({}) } });
    h.seek(60); h.seek(150);
    assert.equal(h.button('undo').disabled, true);
    // The page's timeline owns this release; no document callback follows.
    h.window.emit(release);
    assert.deepEqual([...h.history().state.undo], [30]);
    assert.equal(h.button('undo').disabled, false);
    h.document.emit('pointerup');
    h.button('undo').emit('click'); h.settle();
    assert.equal(h.video.currentTime, 30);
    assert.equal(h.button('redo').hidden, false);
    assert.equal(h.video.paused, false);
  });
}
test('ad transitions and same-element navigation never expose old timeline positions', () => {
  const h = setup(); h.seek(150);
  h.player.attributes.add('ad-showing'); h.observers[0].callback();
  assert.equal(h.host().attributes.has('data-unavailable'), true);
  h.seek(12);
  assert.equal(h.history().state.undo.length, 0);
  h.player.attributes.delete('ad-showing'); h.observers[0].callback();
  h.seek(150); // ad return is not an undoable jump
  assert.equal(h.history().state.undo.length, 0);
  h.seek(200);
  assert.equal(h.history().state.undo.length, 1);
  h.location.href = 'https://www.youtube.com/watch?v=clip-b';
  h.seek(10); // URL guard runs even before parent bridge refresh
  assert.equal(h.history().state.undo.length, 0);
});
test('expired live ranges disable Undo without touching current playback', () => {
  const h = setup(); h.seek(150); h.video.seekable.start = () => 100;
  h.controller.refresh(h.video, 'clip-a');
  assert.equal(h.button('undo').disabled, true);
  h.button('undo').emit('click');
  assert.equal(h.video.currentTime, 150);
});
test('rendering unchanged Redo visibility cannot loop the parent hidden-attribute observer', () => {
  const h = setup(); h.seek(150); h.button('undo').emit('click'); h.settle();
  const writes = h.button('redo').hiddenWrites;
  for (let index = 0; index < 10; index++) h.controller.refresh(h.video, 'clip-a');
  assert.equal(h.button('redo').hiddenWrites, writes);
});
test('cleanup removes every listener, observer, animation frame and overlay, retaining numeric history', () => {
  const h = setup(); h.seek(150); h.controller.dispose();
  assert.equal(h.player.children.length, 0);
  assert.equal(h.frames.size, 0);
  assert.equal(h.eventTargets.reduce((sum, t) => sum + [...t.listeners.values()].reduce((n, s) => n + s.size, 0), 0), 0);
  assert.ok(h.observers.every(o => o.disconnected));
  assert.ok(h.resizers.every(o => o.disconnected));
  const next = h.api.createController(); next.refresh(h.video, 'clip-a');
  assert.deepEqual([...h.history().state.undo], [30]);
  assert.equal(h.player.children.length, 1);
});
test('no active player removes the overlay and media replacement starts an independent history', () => {
  const h = setup(); h.seek(150); h.controller.refresh(null, 'clip-a');
  assert.equal(h.player.children.length, 0);
  h.controller.refresh(h.video, 'clip-b');
  assert.equal(h.history().state.undo.length, 0);
});
test('a replacement isolated controller retires the old tagged overlay', () => {
  const h = setup(); h.seek(150);
  const oldHost = h.host();
  const next = h.api.createController(); next.refresh(h.video, 'clip-a');
  assert.equal(oldHost.connected, false);
  assert.equal(h.player.children.length, 1);
  h.button('undo').emit('click'); h.settle();
  assert.equal(h.video.currentTime, 30);
  next.dispose(); h.controller.dispose();
});
