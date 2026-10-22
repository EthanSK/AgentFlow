/* YouTube seek undo. Local to this tab: no storage, messages, URLs or telemetry. */
(() => {
  const key = '__voiceInkYouTubeSeekHistory';
  // The bridge reinjects content scripts after reconnects. Keep numeric history
  // for the same live element, but never retain removed videos with a strong Map.
  const histories = globalThis[key]?.histories || new WeakMap();
  const LIMIT = 50;
  const EPSILON = 0.35;
  const valid = value => Number.isFinite(value) && value >= 0;
  const different = (a, b) => Math.abs(a - b) > EPSILON;

  function createHistory(initial = null) {
    const state = { undo: [], redo: [], last: valid(initial) ? initial : null,
      pending: null, gesture: null };
    const push = (stack, value) => {
      stack.push(value);
      if (stack.length > LIMIT) stack.shift();
    };
    const record = (from, to) => {
      if (!valid(from) || !valid(to) || !different(from, to)) return;
      push(state.undo, from);
      state.redo.length = 0;
    };
    return {
      state,
      reset(value = null) {
        state.undo.length = state.redo.length = 0;
        state.pending = state.gesture = null;
        state.last = valid(value) ? value : null;
      },
      sample(value, seeking = false) {
        if (!seeking && !state.pending && valid(value)) state.last = value;
      },
      beginGesture(value) {
        if (!state.pending && valid(value)) {
          state.last = value;
          state.gesture = { from: value, active: true, moved: false };
        }
      },
      endGesture(value, seeking) {
        if (!state.gesture) return;
        state.gesture.active = false;
        if (!seeking && !state.pending) {
          if (state.gesture.moved) record(state.gesture.from, value);
          state.gesture = null;
        }
      },
      seeking() {
        if (!state.pending) state.pending = { from: state.last };
      },
      seeked(value) {
        const pending = state.pending;
        state.pending = null;
        if (pending?.direction) {
          // Commit only after the browser reaches our target. An interrupted or
          // rejected seek must not silently consume Undo or manufacture Redo.
          if (valid(value) && !different(value, pending.target)) {
            state[pending.direction].pop();
            push(state[pending.direction === 'undo' ? 'redo' : 'undo'], pending.from);
          } else {
            record(pending.from, value);
          }
        } else if (pending) {
          if (state.gesture) {
            state.gesture.moved ||= valid(value) && different(state.gesture.from, value);
            if (!state.gesture.active) {
              if (state.gesture.moved) record(state.gesture.from, value);
              state.gesture = null;
            }
          } else {
            record(pending.from, value);
          }
        }
        state.last = valid(value) ? value : null;
      },
      cancelPending() {
        state.pending = state.gesture = null;
        state.last = null;
      },
      navigate(direction, current, canSeek, setTime) {
        if (!['undo', 'redo'].includes(direction) || state.pending || state.gesture || !valid(current)) return false;
        const target = state[direction].at(-1);
        if (!valid(target) || !canSeek(target)) return false;
        state.pending = { direction, target, from: current };
        // Some engines omit events for a no-op seek. A position already reached
        // needs no media mutation and must not leave both buttons disabled.
        if (!different(target, current)) {
          this.seeked(current);
          return true;
        }
        try {
          setTime(target);
        } catch {
          state.pending = null;
          return false;
        }
        return true;
      },
    };
  }

  function createController() {
    let binding = null;
    const refresh = (video, identity) => {
      const player = video?.closest('.html5-video-player');
      if (!video || !identity || !player) {
        binding?.dispose();
        binding = null;
        return;
      }
      if (binding?.video === video && binding?.player === player) {
        binding.sync(identity);
        return;
      }
      binding?.dispose();
      binding = bind(video, player, identity);
    };

    function bind(video, player, identity) {
      let saved = histories.get(video);
      if (!saved || saved.identity !== identity) {
        saved = { identity, history: createHistory(video.readyState >= 2 && !video.seeking ? video.currentTime : null) };
        histories.set(video, saved);
      }
      const history = saved.history;
      const removers = [];
      let ad = false;
      let hovered = player.matches(':hover');
      let disposed = false;
      let layoutFrame = 0;
      let speedControl = null;
      // Reload creates a new isolated extension context; the old context's
      // cleanup function is no longer reachable even though its DOM can remain.
      // Retire only our tagged overlays so an inert arrow cannot cover the new
      // controller. Do not touch YouTube or Video Speed Controller elements.
      for (const oldHost of player.querySelectorAll('voiceink-seek-controls[data-voiceink-seek-controls]')) oldHost.remove();
      const host = document.createElement('voiceink-seek-controls');
      host.setAttribute('data-voiceink-seek-controls', '');
      const shadow = host.attachShadow({ mode: 'open' });
      shadow.innerHTML = `<style>
        :host { position:absolute; z-index:60; top:12px; left:12px;
          display:block; max-width:calc(100% - 24px); pointer-events:none; }
        nav { display:flex; gap:4px; flex-wrap:wrap; opacity:0;
          visibility:hidden; transition:opacity .12s; }
        :host([data-visible]) nav, nav:focus-within { opacity:1; visibility:visible; }
        :host([data-unavailable]) { display:none; }
        button { all:initial; box-sizing:border-box; cursor:pointer;
          display:grid; place-items:center; width:28px; height:28px;
          color:white; background:rgba(20,20,20,.25); border:1px solid #ffffff20;
          border-radius:6px; opacity:.65; pointer-events:auto;
          transition:opacity .12s,background .12s; }
        button:hover, button:focus-visible { opacity:1; background:rgba(20,20,20,.6); }
        button:focus-visible { outline:2px solid #8ecaff; outline-offset:2px; }
        button:disabled { opacity:.25; cursor:default; }
        button[hidden] { display:none; }
        svg { width:18px; height:18px; fill:none; stroke:currentColor;
          stroke-width:1.8; stroke-linecap:round; stroke-linejoin:round; pointer-events:none; }
        #redo svg { transform:scaleX(-1); }
        @media(prefers-reduced-motion:reduce) { nav, button { transition:none; } }
      </style><nav aria-label="Video position">
        <button type="button" id="undo" aria-label="Undo last position" title="Undo last position"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m9 4-5 5 5 5M4 9h9a7 7 0 0 1 7 7v4"/></svg></button>
        <button type="button" id="redo" aria-label="Redo" title="Redo" hidden><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m9 4-5 5 5 5M4 9h9a7 7 0 0 1 7 7v4"/></svg></button>
      </nav>`;
      const undo = shadow.getElementById('undo');
      const redo = shadow.getElementById('redo');
      player.append(host);

      const on = (target, event, callback, options) => {
        target.addEventListener(event, callback, options);
        removers.push(() => target.removeEventListener(event, callback, options));
      };
      const isAd = () => player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
      const canSeek = time => {
        if (!valid(time) || video.readyState < 1 || ad || !video.isConnected) return false;
        // Live DVR positions expire. Do not let the browser clamp an old Undo
        // into a different point and then claim that the position was restored.
        for (let index = 0; index < video.seekable.length; index++) {
          if (time >= video.seekable.start(index) && time <= video.seekable.end(index)) return true;
        }
        return false;
      };
      const render = () => {
        const unavailable = ad || !video.isConnected || !video.getClientRects().length;
        host.toggleAttribute('data-unavailable', unavailable);
        host.toggleAttribute('data-visible', hovered || shadow.activeElement !== null);
        undo.disabled = !!history.state.pending || !!history.state.gesture || !canSeek(history.state.undo.at(-1));
        // The parent bridge observes [hidden]. Avoid writing an unchanged value
        // and feeding its refresh observer back into this render indefinitely.
        const hideRedo = !history.state.redo.length;
        if (redo.hidden !== hideRedo) redo.hidden = hideRedo;
        redo.disabled = !!history.state.pending || !!history.state.gesture || !canSeek(history.state.redo.at(-1));
      };
      const sync = nextIdentity => {
        const nextAd = isAd();
        if (saved.identity !== nextIdentity || ad !== nextAd) {
          saved.identity = nextIdentity;
          // YouTube reuses the same element for new clips and adverts. Positions
          // from another timeline must never become an Undo target in this one.
          history.reset();
          ad = nextAd;
        }
        render();
      };
      const syncTimeline = () => {
        const url = new URL(location.href);
        sync(url.pathname.startsWith('/shorts/') ? url.pathname.split('/')[2] : url.searchParams.get('v'));
        return !ad;
      };
      const remember = () => {
        if (syncTimeline() && video.readyState >= 2) history.sample(video.currentTime, video.seeking);
      };
      const layout = () => {
        layoutFrame = 0;
        if (disposed) return;
        // VSC's host has zero height; its visible #controller lives in an open
        // shadow root. Read its rectangle, never mutate another extension's UI.
        const next = player.querySelector('.vsc-controller')?.shadowRoot?.querySelector('#controller');
        if (next !== speedControl) {
          if (speedControl) resize?.unobserve(speedControl);
          speedControl = next || null;
          if (speedControl) resize?.observe(speedControl);
        }
        const bounds = player.getBoundingClientRect();
        const speed = speedControl?.getBoundingClientRect();
        let left = 12;
        let top = 12;
        if (speed?.width && speed?.height) {
          left = Math.max(12, speed.right - bounds.left + 8);
          top = Math.max(12, speed.top - bounds.top);
          if (left + host.getBoundingClientRect().width > bounds.width - 12) {
            left = Math.max(12, Math.min(speed.left - bounds.left, bounds.width - host.getBoundingClientRect().width - 12));
            top = Math.max(12, speed.bottom - bounds.top + 8);
          }
        }
        // CSS positions use layout pixels, rectangles use zoomed screen pixels.
        const scale = bounds.width / player.offsetWidth || 1;
        host.style.left = `${left / scale}px`;
        host.style.top = `${top / scale}px`;
      };
      const scheduleLayout = () => {
        if (!layoutFrame && !disposed) layoutFrame = requestAnimationFrame(layout);
      };
      const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(scheduleLayout) : null;
      resize?.observe(player);
      resize?.observe(host);
      const observer = new MutationObserver(() => { sync(saved.identity); scheduleLayout(); });
      observer.observe(player, { attributes: true, attributeFilter: ['class'], childList: true, subtree: true });
      on(player, 'pointerenter', () => { hovered = true; render(); scheduleLayout(); });
      on(player, 'pointerleave', () => { hovered = false; render(); });
      on(host, 'focusin', render);
      on(host, 'focusout', () => queueMicrotask(render));
      on(window, 'resize', scheduleLayout);
      on(document, 'fullscreenchange', scheduleLayout);
      on(video, 'timeupdate', remember);
      on(video, 'loadeddata', remember);
      on(video, 'durationchange', () => { remember(); render(); });
      on(video, 'emptied', () => { history.reset(); render(); });
      on(video, 'error', () => { history.cancelPending(); render(); });
      on(video, 'abort', () => { history.cancelPending(); render(); });
      // HTML seeking sets currentTime before queuing 'seeking'. Keep the last
      // non-seeking sample; never infer seeks from timer gaps or playback rate.
      // Spec: https://html.spec.whatwg.org/multipage/media.html#seeking
      on(video, 'seeking', () => { if (syncTimeline()) history.seeking(); render(); });
      on(video, 'seeked', () => { if (syncTimeline()) history.seeked(video.currentTime); render(); scheduleLayout(); });
      on(player, 'keydown', remember, true);
      on(player, 'pointerdown', event => {
        if (event.composedPath().includes(host)) return;
        remember();
        // A timeline drag can emit several complete seeks; one Undo returns to
        // the position before that drag, not the last intermediate scrub frame.
        if (event.target.closest?.('.ytp-progress-bar, .ytp-progress-list')) {
          history.beginGesture(video.currentTime);
        }
      }, true);
      on(player, 'pointerup', scheduleLayout);
      const endGesture = () => { history.endGesture(video.currentTime, video.seeking); render(); };
      // YouTube can capture a timeline's pointer and stop its release before it
      // reaches document. Observe the release at window capture, and retain
      // mouseup for native/legacy mouse controls that omit pointerup. A missed
      // release otherwise leaves a completed seek marked as an active drag,
      // disabling Undo indefinitely. Duplicate release edges are harmless.
      on(window, 'pointerup', endGesture, true);
      on(window, 'pointercancel', endGesture, true);
      on(window, 'mouseup', endGesture, true);
      on(document, 'pointerup', endGesture, true);
      on(document, 'pointercancel', endGesture, true);
      on(window, 'blur', endGesture);
      for (const event of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'keydown', 'keyup']) {
        on(host, event, e => e.stopPropagation());
      }
      const navigate = direction => {
        if (!syncTimeline()) return;
        history.navigate(direction, video.currentTime, canSeek, time => { video.currentTime = time; });
        // No play(), pause(), focus(), global key, or VoiceInk ownership message.
        render();
      };
      on(undo, 'click', () => navigate('undo'));
      on(redo, 'click', () => navigate('redo'));
      sync(identity);
      scheduleLayout();
      return { video, player, sync, remember, dispose() {
        disposed = true;
        removers.forEach(remove => remove());
        observer.disconnect();
        resize?.disconnect();
        if (layoutFrame) cancelAnimationFrame(layoutFrame);
        // A drag cannot remain active after its listener is removed.
        history.endGesture(video.currentTime, video.seeking);
        host.remove();
      } };
    }
    return { refresh, remember: () => binding?.remember(), dispose() { binding?.dispose(); binding = null; } };
  }
  globalThis[key] = { histories, createHistory, createController };
})();
