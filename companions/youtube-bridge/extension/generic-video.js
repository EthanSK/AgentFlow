/* global chrome */
// Ordinary website players and embedded frames. YouTube's top-level adapter remains separate:
// Shorts, Jump ahead, and its player-button resume fallback are not generic browser contracts.
(() => {
  if (/^([^.]+\.)?youtube\.com$/i.test(location.hostname) && window.top === window) return;
  const key = '__voiceInkGenericVideoBridge';
  if (globalThis[key]) {
    if (globalThis[key].extensionId === chrome.runtime.id && globalThis[key].isAlive()) {
      globalThis[key].report('state-request'); return;
    }
    globalThis[key].dispose();
  }
  const instanceId = crypto.randomUUID();
  const records = new Map();
  const byVideo = new WeakMap();
  const roots = new Set();
  const observers = [];
  let preferred = null;
  let speedHold = null;
  let holdTimer = null;
  let disposed = false;
  let refreshQueued = false;
  let lastState = '';
  const playing = v => !v.paused && !v.ended;
  const send = m => { try { chrome.runtime.sendMessage(m, () => void chrome.runtime.lastError); } catch { /* Invalidated extension context. */ } };
  const clip = r => `${r.generation}:${r.video.currentSrc || r.video.src || ''}`;
  const writePlaybackRate = (record, rate, phase) => {
    const id = crypto.randomUUID();
    let response = null;
    const receive = event => {
      try { const value = JSON.parse(event.detail); if (value.id === id) response = value; } catch { /* Unrelated page event. */ }
    };
    record.video.addEventListener('voiceink-video-rate-response', receive);
    try {
      record.video.dispatchEvent(new CustomEvent('voiceink-video-rate-request', {
        detail: JSON.stringify({id, rate, phase}), bubbles: true, composed: true,
      }));
    } finally { record.video.removeEventListener('voiceink-video-rate-response', receive); }
    // The page-world helper runs synchronously on this exact element. Plain players still work
    // without it; a controller that explicitly rejects cooperation must not be bypassed.
    if (response === null) record.video.playbackRate = rate;
    return {ok: response?.ok !== false && record.video.playbackRate === rate, reason: response?.reason || ''};
  };
  const visibleArea = v => {
    const rect = v.getBoundingClientRect();
    const style = getComputedStyle(v);
    if (v.hidden || style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return 0;
    return Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0)) *
      Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
  };
  const selected = () => {
    const values = [...records.values()].filter(r => r.video.isConnected);
    const pip = values.find(r => r.video === document.pictureInPictureElement);
    if (pip) return pip;
    // A deliberate player interaction outranks autoplay previews. Otherwise prefer a visible,
    // playing, audible player and its rendered area, never document-order alone.
    if (preferred?.video.isConnected && (visibleArea(preferred.video) > 0 || playing(preferred.video))) return preferred;
    return values.sort((a, b) => {
      const score = r => (visibleArea(r.video) > 0 ? 1e9 : 0) +
        (playing(r.video) ? 1e8 : 0) + (!r.video.muted && r.video.volume > 0 ? 1e7 : 0) + visibleArea(r.video);
      return score(b) - score(a);
    })[0] ?? null;
  };
  const report = (reason = 'heartbeat') => {
    const r = selected();
    // No media means no periodic traffic/storage/log churn on ordinary text pages.
    if (!r && !lastState) return;
    const state = r ? `${r.id}|${clip(r)}|${playing(r.video)}|${r.video === document.pictureInPictureElement}|${r.interactedAt}` : 'none';
    if (state === lastState && reason !== 'heartbeat' && reason !== 'state-request') return;
    lastState = state;
    send({ type: 'generic-video-state', instanceId, mediaId: r?.id ?? null,
      playing: r ? playing(r.video) : false, isPiP: r?.video === document.pictureInPictureElement,
      audible: r ? !r.video.muted && r.video.volume > 0 : false,
      area: r ? visibleArea(r.video) : 0, interactedAt: r?.interactedAt ?? 0,
      reason, contentTimestamp: Date.now() });
  };
  const restoreHold = (token, restorePlaybackRate) => {
    if (!speedHold || speedHold.token !== token) return { ok: false, speedHeld: false, reason: 'hold-token-mismatch' };
    const hold = speedHold;
    speedHold = null;
    clearTimeout(holdTimer);
    const result = writePlaybackRate(hold.record, restorePlaybackRate ?? hold.previousPlaybackRate, 'restore');
    return { ok: result.ok, reason: result.reason,
      speedHeld: false, playbackRate: hold.record.video.playbackRate, previousPlaybackRate: hold.previousPlaybackRate };
  };
  const releaseChangedClip = r => {
    r.generation += 1;
    r.pausedByUs = null;
    if (speedHold?.record === r) restoreHold(speedHold.token);
    report('clip-changed');
  };
  const register = video => {
    if (byVideo.has(video)) return;
    const r = { id: crypto.randomUUID(), video, generation: 0, interactedAt: 0,
      pendingPause: 0, pendingPlay: 0, pausedByUs: null, detach: [] };
    records.set(r.id, r);
    byVideo.set(video, r);
    const listen = (type, fn) => { video.addEventListener(type, fn); r.detach.push(() => video.removeEventListener(type, fn)); };
    for (const type of ['play', 'pause']) listen(type, () => {
      const counter = type === 'pause' ? 'pendingPause' : 'pendingPlay';
      if (r[counter] > 0) r[counter] -= 1;
      else if (navigator.userActivation?.isActive === true || Date.now() - r.interactedAt < 1200) {
        r.pausedByUs = null;
        send({ type: 'generic-video-manual-control', instanceId, mediaId: r.id,
          action: type, contentTimestamp: Date.now() });
      }
      report(type);
    });
    for (const type of ['playing', 'ended', 'enterpictureinpicture', 'leavepictureinpicture', 'volumechange']) listen(type, () => report(type));
    listen('emptied', () => releaseChangedClip(r));
    listen('loadedmetadata', () => {
      if (r.pausedByUs && r.pausedByUs !== clip(r)) r.pausedByUs = null;
      if (speedHold?.record === r && speedHold.clip !== clip(r)) restoreHold(speedHold.token);
      report('loadedmetadata');
    });
  };
  const interaction = event => {
    // composedPath supports open shadow-root players; controls beside a video identify their
    // nearest unambiguous player container without mistaking a click elsewhere for a selection.
    const path = event.composedPath();
    let v = path.find(n => n instanceof HTMLVideoElement);
    if (!v) for (const node of path) {
      if (!node?.querySelectorAll || node === document || node === document.documentElement || node === document.body) break;
      const candidates = node.querySelectorAll('video');
      if (candidates.length === 1) { v = candidates[0]; break; }
      if (candidates.length > 1) break;
    }
    if (v) { register(v); preferred = byVideo.get(v); preferred.interactedAt = Date.now(); report('interaction'); }
  };
  const scan = root => {
    if (!roots.has(root)) {
      roots.add(root);
      root.addEventListener('pointerdown', interaction, true);
      root.addEventListener('keydown', interaction, true);
      const observer = new MutationObserver(mutations => {
        // Inspect new subtrees rather than repeatedly walking a whole live chat/feed DOM.
        for (const mutation of mutations) for (const node of mutation.addedNodes) discoverNode(node);
        if (!refreshQueued) { refreshQueued = true; queueMicrotask(() => { refreshQueued = false; refresh(); }); }
      });
      observer.observe(root, { childList: true, subtree: true });
      observers.push(observer);
      for (const v of root.querySelectorAll('video')) register(v);
      for (const element of root.querySelectorAll('*')) if (element.shadowRoot) scan(element.shadowRoot);
    }
  };
  const discoverNode = node => {
    if (node instanceof HTMLVideoElement) register(node);
    if (node?.shadowRoot) scan(node.shadowRoot);
    for (const v of node?.querySelectorAll?.('video') ?? []) register(v);
    for (const element of node?.querySelectorAll?.('*') ?? []) if (element.shadowRoot) scan(element.shadowRoot);
  };
  const refresh = () => {
    if (disposed) return;
    scan(document);
    for (const [id, r] of records) if (!r.video.isConnected) {
      if (speedHold?.record === r) restoreHold(speedHold.token);
      r.detach.forEach(fn => fn()); records.delete(id); byVideo.delete(r.video);
      if (preferred === r) preferred = null;
    }
    if (speedHold && speedHold.clip !== clip(speedHold.record)) restoreHold(speedHold.token);
    report('video-attached');
  };
  const handle = (message, sender, respond) => {
    if (sender.id !== chrome.runtime.id || message?.type !== 'generic-video-command') return false;
    if (Number.isFinite(message.expiresAt) && Date.now() >= message.expiresAt) {
      respond({ ok: false, reason: 'playback-command-expired' }); return false;
    }
    if (message.command === 'state-request') { refresh(); report('state-request'); respond({ ok: true }); return false; }
    if (message.instanceId !== instanceId) { respond({ ok: false, reason: 'document-changed' }); return false; }
    const r = records.get(message.mediaId);
    if (!r?.video.isConnected) { respond({ ok: false, reason: 'player-changed' }); return false; }
    const v = r.video;
    try {
      switch (message.command) {
        case 'pause-youtube':
          if (r.pausedByUs && r.pausedByUs !== clip(r)) { respond({ ok: false, reason: 'clip-changed' }); return false; }
          if (!playing(v)) { respond({ ok: true, paused: false, reason: 'not-playing' }); return false; }
          r.pendingPause += 1; v.pause(); r.pausedByUs = v.paused ? clip(r) : null;
          report('voiceink-pause'); respond({ ok: v.paused, paused: v.paused }); return false;
        case 'resume-youtube':
          // A remembered tab/frame alone cannot authorize playback. The same element and clip
          // must still carry our pause lease; manual play/pause, navigation and replacement revoke it.
          if (!r.pausedByUs || r.pausedByUs !== clip(r) || v.ended) { respond({ ok: false, resumed: false, reason: 'pause-ownership-lost' }); return false; }
          if (playing(v)) { respond({ ok: true, resumed: false, reason: 'already-playing' }); return false; }
          r.pendingPlay += 1;
          Promise.resolve(v.play()).then(() => {
            report('voiceink-resume'); respond({ ok: playing(v), resumed: playing(v) });
          }, () => { r.pendingPlay = Math.max(0, r.pendingPlay - 1); respond({ ok: false, resumed: false, reason: 'play-blocked' }); });
          return true;
        case 'toggle-youtube':
          r.pausedByUs = null;
          send({ type: 'generic-video-manual-control', instanceId, mediaId: r.id, action: v.paused ? 'play' : 'pause', contentTimestamp: Date.now() });
          if (playing(v)) { r.pendingPause += 1; v.pause(); report('native-toggle'); respond({ ok: v.paused }); return false; }
          r.pendingPlay += 1;
          Promise.resolve(v.play()).then(() => { report('native-toggle'); respond({ ok: playing(v) }); }, () => {
            r.pendingPlay = Math.max(0, r.pendingPlay - 1); respond({ ok: false, reason: 'play-blocked' });
          }); return true;
        case 'seek-youtube': {
          if (message.seekSeconds !== 5 && message.seekSeconds !== -5) break;
          let target = Math.max(0, v.currentTime + message.seekSeconds);
          if (Number.isFinite(v.duration)) target = Math.min(target, v.duration);
          if (v.seekable?.length) target = Math.max(v.seekable.start(0), Math.min(target, v.seekable.end(v.seekable.length - 1)));
          v.currentTime = target; respond({ ok: v.currentTime === target, sought: v.currentTime === target }); return false;
        }
        case 'adjust-youtube-volume': {
          if (!playing(v) || (message.volumeDelta !== .05 && message.volumeDelta !== -.05)) break;
          const volume = Math.min(1, Math.max(0, v.volume + message.volumeDelta));
          v.volume = volume; if (message.volumeDelta > 0) v.muted = false;
          respond({ ok: v.volume === volume, volumeAdjusted: v.volume === volume, volume: v.volume, muted: v.muted }); return false;
        }
        case 'begin-youtube-speed-hold':
        case 'renew-youtube-speed-hold':
        case 'end-youtube-speed-hold': {
          if (typeof message.holdToken !== 'string' || message.playbackRate !== 2 || !Number.isInteger(message.holdLeaseMilliseconds) ||
              message.holdLeaseMilliseconds < 1500 || message.holdLeaseMilliseconds > 5000 ||
              (message.restorePlaybackRate !== undefined && (message.command !== 'end-youtube-speed-hold' || message.restorePlaybackRate !== 1))) break;
          if (message.command === 'end-youtube-speed-hold') { respond(restoreHold(message.holdToken, message.restorePlaybackRate)); return false; }
          if (message.command === 'renew-youtube-speed-hold' && (!speedHold || speedHold.token !== message.holdToken)) {
            respond({ ok: false, reason: 'hold-token-mismatch' }); return false;
          }
          if (speedHold && (speedHold.token !== message.holdToken || speedHold.record !== r || speedHold.clip !== clip(r))) restoreHold(speedHold.token);
          if (!speedHold) {
            if (message.command !== 'begin-youtube-speed-hold' || !playing(v)) { respond({ ok: false, reason: 'no-playing-video' }); return false; }
            speedHold = { token: message.holdToken, record: r, clip: clip(r), previousPlaybackRate: v.playbackRate };
          }
          const write = writePlaybackRate(r, 2, 'hold');
          if (!write.ok) {
            // A failed renewal can follow a successful begin. Restore that exact hold before
            // dropping its lease; otherwise a controller exception could leave unowned 2×.
            restoreHold(message.holdToken);
            respond({ok: false, speedHeld: false, reason: write.reason || 'media-control-failed'}); return false;
          }
          clearTimeout(holdTimer);
          holdTimer = setTimeout(() => restoreHold(message.holdToken), message.holdLeaseMilliseconds);
          respond({ ok: v.playbackRate === 2, speedHeld: v.playbackRate === 2, playbackRate: v.playbackRate, previousPlaybackRate: speedHold.previousPlaybackRate }); return false;
        }
        case 'jump-ahead-youtube':
          respond({ ok: false, jumpAheadClicked: false, reason: 'youtube-only-control' }); return false;
      }
      respond({ ok: false, reason: 'invalid-media-command' });
    } catch { respond({ ok: false, reason: 'media-control-failed' }); }
    return false;
  };
  chrome.runtime.onMessage.addListener(handle);
  const timer = setInterval(() => { refresh(); if (records.size) report('heartbeat'); }, 5000);
  const dispose = () => {
    disposed = true; if (speedHold) restoreHold(speedHold.token); clearInterval(timer);
    observers.forEach(o => o.disconnect());
    for (const root of roots) { root.removeEventListener('pointerdown', interaction, true); root.removeEventListener('keydown', interaction, true); }
    for (const r of records.values()) r.detach.forEach(fn => fn());
    try { chrome.runtime.onMessage.removeListener(handle); } catch { /* Invalidated context. */ }
    window.removeEventListener('pagehide', dispose);
    if (globalThis[key]?.instanceId === instanceId) delete globalThis[key];
  };
  const isAlive = () => { try { chrome.runtime.getManifest(); return true; } catch { return false; } };
  globalThis[key] = { extensionId: chrome.runtime.id, instanceId, isAlive, report, dispose };
  window.addEventListener('pagehide', dispose, { once: true });
  refresh();
})();
