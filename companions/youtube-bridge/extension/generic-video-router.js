/* global chrome */
// Keep Chrome's document identity, frame, content-instance and exact media token together.
// Old native command names remain an IPC contract, not a YouTube-only implementation.
function createGenericVideoRouter(chromeAPI = chrome) {
  // A frozen frame can leave Chrome's injection/message promise pending forever. Bound the
  // individual browser wait, not the whole recording operation: abandoned async operations
  // must never continue issuing playback commands after a newer recording owns the queue.
  const browserTimeoutMs = 2000;
  const waitForBrowser = (operation, phase) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`browser-timeout:${phase}`)), browserTimeoutMs);
    Promise.resolve().then(operation).then(resolve, reject).finally(() => clearTimeout(timer));
  });
  const frames = new Map();
  const storageKey = 'genericVideoOwnedTargetsV1';
  let leases = {};
  let loaded = false;
  const validTarget = target => target && Number.isInteger(target.tabId) && Number.isInteger(target.frameId) &&
    typeof target.instanceId === 'string' && typeof target.mediaId === 'string';
  const load = async () => {
    if (loaded) return;
    const stored = await waitForBrowser(() => chromeAPI.storage.local.get(storageKey), 'media-ownership-read');
    const value = stored[storageKey];
    leases = value && typeof value === 'object' ? value : {};
    loaded = true;
  };
  const save = () => waitForBrowser(() => chromeAPI.storage.local.set({ [storageKey]: leases }), 'media-ownership-save');
  const accept = (message, sender) => {
    if (sender.id !== chromeAPI.runtime.id || !Number.isInteger(sender.tab?.id) || !Number.isInteger(sender.frameId) ||
        !/^https?:\/\//.test(sender.url || '') || typeof message.instanceId !== 'string') return null;
    const target = { tabId: sender.tab.id, frameId: sender.frameId, documentId: sender.documentId,
      instanceId: message.instanceId, mediaId: message.mediaId };
    const key = `${target.tabId}:${target.frameId}`;
    if (!validTarget(target)) { frames.delete(key); return aggregate(target.tabId); }
    const previous = frames.get(key);
    const didStart = message.playing === true && (previous?.playing !== true ||
      previous.mediaId !== target.mediaId || ['play', 'playing', 'native-toggle', 'voiceink-resume'].includes(message.reason));
    frames.set(key, { ...target, playing: message.playing === true, isPiP: message.isPiP === true,
      audible: message.audible === true, area: Math.max(0, Math.min(Number(message.area) || 0, 1e8)),
      interactedAt: Number(message.interactedAt) || 0,
      lastPlayedAt: didStart ? Date.now() : previous?.lastPlayedAt ?? 0 });
    return aggregate(target.tabId);
  };
  const aggregate = tabId => {
    const eligible = [...frames.values()].filter(t => t.tabId === tabId);
    eligible.sort((a, b) => Number(b.isPiP) - Number(a.isPiP) || b.interactedAt - a.interactedAt ||
      Number(b.playing) - Number(a.playing) || Number(b.audible) - Number(a.audible) || b.area - a.area || b.lastPlayedAt - a.lastPlayedAt);
    return eligible[0] ?? null;
  };
  const rawSend = (target, message) => waitForBrowser(() => new Promise(resolve => {
    const options = target.documentId ? { documentId: target.documentId } : { frameId: target.frameId };
    try {
      chromeAPI.tabs.sendMessage(target.tabId, { ...message, type: 'generic-video-command', command: message.type,
        instanceId: target.instanceId, mediaId: target.mediaId }, options, response => {
        const error = chromeAPI.runtime.lastError;
        resolve({ delivered: !error, response: response ?? { ok: false, reason: 'missing-response' }, reason: error?.message ?? '' });
      });
    } catch { resolve({ delivered: false, response: null, reason: 'document-unavailable' }); }
  }), 'media-message');
  const discover = async tabId => {
    // Only initial discovery can inject all frames. A bound resume/renew/end never reinjects:
    // rebuilding page state would discard pause ownership or silently bind another clip.
    await waitForBrowser(() => chromeAPI.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['generic-rate-bridge.js'], world: 'MAIN' }), 'generic-rate-injection');
    await waitForBrowser(() => chromeAPI.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['generic-video.js'] }), 'generic-video-injection');
    return aggregate(tabId);
  };
  const send = async (tabId, message, canSend = () => true) => {
    try {
      await load();
      const speedKey = typeof message.holdToken === 'string' ? `speed:${message.holdToken}` : null;
      const pauseKey = `pause:${tabId}`;
      const resume = message.type === 'resume-youtube';
      const speedExisting = speedKey && leases[speedKey];
      const bound = resume ? leases[pauseKey] :
        ['renew-youtube-speed-hold', 'end-youtube-speed-hold'].includes(message.type) ? speedExisting :
          message.type === 'pause-youtube' ? leases[pauseKey] : speedExisting;
      const requiresBound = resume || message.type === 'renew-youtube-speed-hold' || message.type === 'end-youtube-speed-hold';
      let target = validTarget(bound) ? bound : null;
      if (!target && requiresBound) return { delivered: true, response: { ok: false, reason: 'media-ownership-lost' }, reason: '' };
      if (!target) target = aggregate(tabId) ?? await discover(tabId);
      if (!target) return { delivered: true, response: { ok: false, reason: 'no-video' }, reason: '' };
      if (!canSend()) return { delivered: false, response: null, reason: 'playback-command-superseded' };
      // Pages reject late delivery themselves; a worker timeout alone cannot cancel a queued
      // message in a frozen renderer. Preserve exact document/media identity as before.
      const result = await rawSend(target, { ...message, expiresAt: Date.now() + browserTimeoutMs });
      // Persist before returning pause success: a sleeping worker must retain the exact document.
      if (message.type === 'pause-youtube' && result.response?.paused === true) { leases[pauseKey] = target; await save(); }
      if (message.type === 'begin-youtube-speed-hold' && result.response?.speedHeld === true) { leases[speedKey] = target; await save(); }
      if (message.type === 'end-youtube-speed-hold') { delete leases[speedKey]; await save(); }
      return result;
    } catch (error) { return { delivered: false, response: null,
      reason: String(error?.message || '').startsWith('browser-timeout:') ? error.message : 'generic-media-route-unavailable' }; }
  };
  const clearPause = async () => {
    try { await load(); for (const key of Object.keys(leases)) if (key.startsWith('pause:')) delete leases[key]; await save(); } catch { /* Fail closed. */ }
  };
  const owns = async tabId => {
    try { await load(); return Object.values(leases).some(t => validTarget(t) && t.tabId === tabId); }
    catch { return true; } // Unreadable ownership must never fall through into a different adapter.
  };
  const navigated = tabId => {
    // Discard candidate reports but retain owned document IDs until their normal end edge.
    // A generic tab navigating to YouTube must not turn an old resume into a new YouTube play.
    for (const [key, target] of frames) if (target.tabId === tabId) frames.delete(key);
  };
  const removed = tabId => {
    for (const [key, target] of frames) if (target.tabId === tabId) frames.delete(key);
    void load().then(() => { for (const [key, target] of Object.entries(leases)) if (target.tabId === tabId) delete leases[key]; return save(); });
  };
  return { accept, aggregate, send, discover, clearPause, owns, navigated, removed, waitForBrowser, browserTimeoutMs };
}
