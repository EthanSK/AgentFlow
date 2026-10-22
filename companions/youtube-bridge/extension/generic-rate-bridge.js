// A page-world rate adapter, not a native-message or cross-site bridge. Websites can already
// change their own media; this event accepts only one exact video and a bounded playback rate.
// Keep temporary holds out of Video Speed Controller's saved/global speed authority.
(() => {
  if (/^([^.]+\.)?youtube\.com$/i.test(location.hostname) && window.top === window) return;
  const key = '__voiceInkGenericRateBridge';
  if (globalThis[key]) return;
  const requestType = 'voiceink-video-rate-request';
  const responseType = 'voiceink-video-rate-response';
  const handle = event => {
    const video = event.composedPath()[0];
    if (!(video instanceof HTMLVideoElement) || !video.isConnected) return;
    let request;
    try { request = JSON.parse(event.detail); } catch { return; }
    if (!request || typeof request.id !== 'string' || !['hold', 'restore'].includes(request.phase) ||
        !Number.isFinite(request.rate) || request.rate < 0 || request.rate > 16 ||
        (request.phase === 'hold' && request.rate !== 2)) return;
    let reason = '';
    const previousRate = video.playbackRate;
    try {
      const controller = globalThis.VSC_controller;
      const action = controller?.actionHandler;
      const arbitration = controller?.eventManager?.arbitration;
      const temporary = globalThis.VSC?.IntentClassifier?.VERDICTS?.TEMPORARY_OVERRIDE;
      if (video.vsc) {
        // VSC 0.11 exposes an exact-media write plus a temporary-override reducer. Its normal
        // adjustSpeed API persists authority, so never use it for a momentary native hold.
        // An incompatible controller fails closed instead of fighting its ratechange handler.
        if (typeof action?.writeRate !== 'function' || typeof action?.syncIndicator !== 'function' ||
            typeof arbitration?.onExternalRate !== 'function' ||
            typeof arbitration?.completeTemporaryOverride !== 'function' || typeof temporary !== 'string') {
          reason = 'incompatible-speed-controller';
        } else if (request.phase === 'hold') {
          action.writeRate(video, request.rate);
          arbitration.onExternalRate(video, event, temporary);
          action.syncIndicator(video, request.rate);
        } else {
          arbitration.completeTemporaryOverride(video, request.rate);
          action.writeRate(video, request.rate);
          action.syncIndicator(video, request.rate);
        }
      } else video.playbackRate = request.rate;
    } catch {
      // A controller exception after its write must not strand a rejected begin at 2×.
      try { video.playbackRate = request.phase === 'restore' ? request.rate : previousRate; } catch { /* Report failure below. */ }
      reason = 'media-control-failed';
    }
    video.dispatchEvent(new CustomEvent(responseType, {detail: JSON.stringify({id: request.id,
      ok: !reason && video.playbackRate === request.rate, reason})}));
  };
  window.addEventListener(requestType, handle, true);
  globalThis[key] = true;
})();
