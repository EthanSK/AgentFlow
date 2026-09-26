// One timing model for the whole promo, derived from narration.json.
//
// render.mjs builds it once and hands the same object to scene.html (as window.PROMO) and to
// music.mjs, so the picture, the interface sounds and the music can never drift apart. Every
// on-screen action is an offset from the start of the spoken line it illustrates; changing a
// segment's start (or a voice take running long) moves its actions with it.

export const FPS = 30;
export const SAMPLE_RATE = 48000;

// The scene choreographs these lines by id; narration.json must keep all of them.
export const REQUIRED_SEGMENTS = [
  "intro", "talk", "dictate1", "highlight", "dictate2", "screenshot", "paste", "outro",
];

// A word shows in the recorder once most of it has been said, like live transcription.
const WORD_REVEAL_POINT = 0.75;
const WORD_REVEAL_LAG = 0.06;

// Vowel-group syllable count. Only used for rough estimates and to share a dictation line's
// spoken time between its words, so an approximate count is enough.
export function syllables(word) {
  const w = word.toLowerCase().replace(/[^a-z]/g, "");
  if (!w) return 1;
  let groups = (w.match(/[aeiouy]+/g) || []).length;
  if (w.length > 2 && w.endsWith("e") && !/[aeiouy]e$/.test(w) && groups > 1) groups -= 1;
  return Math.max(1, groups);
}

// Rough speaking time for a line with no voice file yet (stills, drafts, --plan): about
// 4.4 syllables a second plus a short pause at each mid-line punctuation mark.
export function estimateSpeech(text) {
  const words = text.split(/\s+/).filter(Boolean);
  const pauses = (text.match(/[.,;:!?](?=\s)/g) || []).length;
  return words.reduce((sum, w) => sum + syllables(w), 0) / 4.4 + pauses * 0.25;
}

// Maps a fraction of a take's voiced time to seconds from its first sound. `voiced` is a list
// of [from, to] spans with sound, relative to the trimmed take; pauses between them are skipped.
function voicedTime(voiced, fraction) {
  const total = voiced.reduce((sum, [a, b]) => sum + (b - a), 0);
  let remaining = fraction * total;
  for (const [a, b] of voiced) {
    if (remaining <= b - a) return a + remaining;
    remaining -= b - a;
  }
  return voiced.length ? voiced[voiced.length - 1][1] : 0;
}

/**
 * narration: parsed narration.json.
 * measured: optional { [id]: { duration, voiced } } from the real voice takes, in seconds.
 */
export function buildTimeline(narration, measured = {}) {
  const ids = narration.segments.map((s) => s.id);
  const missing = REQUIRED_SEGMENTS.filter((id) => !ids.includes(id));
  if (missing.length) throw new Error(`narration.json is missing segment(s): ${missing.join(", ")}`);

  const beat = 60 / narration.bpm;
  const seg = {};
  const shifts = [];
  let shift = 0;
  let previous = null;
  for (const s of narration.segments) {
    const take = measured[s.id];
    const duration = take ? take.duration : estimateSpeech(s.text);
    let start = s.start + shift;
    if (previous && previous.end + narration.minGap > start + 1e-6) {
      // A take ran into the next line. Delay this and every later line by whole beats, so the
      // actions tied to them stay on the music's grid.
      const by = Math.ceil((previous.end + narration.minGap - start) / beat - 1e-9) * beat;
      shift += by;
      start += by;
      shifts.push({ id: s.id, by: Number(by.toFixed(3)) });
    }
    const voiced = take?.voiced?.length ? take.voiced : [[0, duration]];
    seg[s.id] = {
      id: s.id, kind: s.kind, text: s.text, declaredStart: s.start,
      start, duration, end: start + duration, voiced, measured: Boolean(take),
    };
    previous = seg[s.id];
  }

  let duration = narration.duration + shift;
  if (previous.end + 1 > duration) duration = Math.ceil((previous.end + 1.5) * 10) / 10;

  // Live words for the recorder, in spoken order.
  const words = {};
  for (const s of Object.values(seg)) {
    if (s.kind !== "dictation") continue;
    const list = s.text.split(/\s+/).filter(Boolean);
    const weights = list.map(syllables);
    const total = weights.reduce((a, b) => a + b, 0);
    let done = 0;
    words[s.id] = list.map((text, i) => {
      const point = (done + WORD_REVEAL_POINT * weights[i]) / total;
      done += weights[i];
      return { text, at: s.start + voicedTime(s.voiced, point) + WORD_REVEAL_LAG };
    });
  }

  const S = (id) => seg[id].start;
  // Every on-screen action, as an offset from the line it illustrates. With the default
  // starts, the groove, highlight, screenshot, stop and paste land on beats of the 100 bpm
  // music. Offsets inside a line follow where its words fall in the narrator's take.
  const moments = {
    titleOut: S("talk") - 0.5,      // title lifts away once the first line is finished
    deskIn: S("talk") - 0.2,        // menu bar, windows and Dock settle in once it's gone
    press: S("talk") + 0.3,         // shortcut pressed: "Press your shortcut…"
    hudIn: S("talk") + 0.6,         // recorder is up
    dragStart: S("highlight") + 0.2, // "Highlight the code you mean…"
    dragEnd: S("highlight") + 1.0,
    selLand: S("highlight") + 1.8,  // Selected Text joins the live words: "…no copying needed."
    crossOn: S("screenshot") + 0.1,
    shotStart: S("screenshot") + 0.3,
    shotEnd: S("screenshot") + 0.95,
    shutter: S("screenshot") + 1.2, // just after "Take a screenshot"
    shotLand: S("screenshot") + 1.8, // Screenshot reference joins the live words
    dockClick: S("paste") - 0.6,    // Codex comes forward with its composer focused
    stop: S("paste"),               // "Press again…"
    pasteLand: S("paste") + 1.2,    // one paste, as she says "…and Agent Flow pastes it all…"
    glowSel: S("paste") + 4.1,      // "…so your agent can see…"
    glowShot: S("paste") + 5.0,     // "…what you were looking at."
    endIn: S("outro") - 1.2,
    endDetails: S("outro") + 1.5,   // "Open source, for Mac."
  };

  return { fps: FPS, sampleRate: SAMPLE_RATE, bpm: narration.bpm, beat, duration, seg, words, moments, shifts };
}
