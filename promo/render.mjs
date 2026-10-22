// Renders the narrated Agent Flow promo.
//
// Pipeline:
//   narration.json ─► timeline.mjs ─► window.PROMO in scene.html ─► headless Chrome frames ─► H.264
//                                 └─► music.mjs (music + interface sounds)
//   voice takes (one file per narration segment) ─► trimmed, placed, mixed over the ducked
//   music ─► loudness-normalized master ─► AAC, muxed with the picture
//   captions (WebVTT) come from the same segment text and measured timing.
//
// Why frame-by-frame instead of screen recording: the scene has no timers or CSS animations,
// so each frame is a pure function of time. Output is identical on every run, never drops
// frames, and never opens a visible window.
//
// Modes (run from this folder after `npm ci`; see README.md):
//   node render.mjs --plan [--voice DIR]          timing budgets, and real take lengths
//   node render.mjs --stills --out DIR [times…]   PNG stills
//   node render.mjs --draft --out FILE.mp4 [--voice DIR]   preview anywhere outside docs/
//   node render.mjs --voice DIR                   final video, captions and poster in docs/assets
//   node render.mjs --reuse-audio [--out FILE.mp4]
//       the current picture over the PUBLISHED soundtrack, copied packet for packet, on the
//       timing its captions record. Without --out it replaces the published video and poster
//       (captions stay byte-identical) and writes promo/published-video.json. --plan and
//       --stills accept --reuse-audio too, to check that timing before rendering.
// Options: --scale N (device scale, default 2), --work DIR (frame cache), --fresh (ignore cache),
//   --source FILE.mp4 and --captions FILE.vtt (reuse-audio inputs; default: the published ones).
//
// Requirements: Google Chrome (channel "chrome") and ffmpeg/ffprobe (4.4+, for streamhash) on PATH.

import { chromium } from "playwright-core";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { buildTimeline, FPS, SAMPLE_RATE } from "./timeline.mjs";
import { renderSoundtrack, reverb } from "./music.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..");
const docs = resolve(here, "..", "docs");
const FINAL = {
  video: join(docs, "assets", "agentflow-promo.mp4"),
  captions: join(docs, "assets", "agentflow-promo.vtt"),
  poster: join(docs, "assets", "agentflow-promo-poster.jpg"),
};
// Provenance of the published video: which soundtrack it carries and what drew the picture.
const RECEIPT = join(here, "published-video.json");

// ---------- Arguments ----------

const args = process.argv.slice(2);
const valueOptions = ["--voice", "--out", "--work", "--scale", "--source", "--captions"];
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const optionValueIndexes = new Set(valueOptions.map((name) => args.indexOf(name) + 1).filter((i) => i > 0));
const times = args.filter((a, i) => !optionValueIndexes.has(i) && /^\d+(\.\d+)?$/.test(a)).map(Number);
const reuse = args.includes("--reuse-audio");
const mode = args.includes("--plan") ? "plan" : args.includes("--stills") ? "stills" : args.includes("--draft") ? "draft" : reuse ? "reuse" : "final";
const voiceDir = option("--voice") && resolve(option("--voice"));
const outPath = option("--out") && resolve(option("--out"));
const workDir = resolve(option("--work") || join(tmpdir(), "agentflow-promo-work"));
const deviceScale = Number(option("--scale") || 2);
const fresh = args.includes("--fresh");
const sourceVideo = resolve(option("--source") || FINAL.video);
const sourceCaptions = resolve(option("--captions") || FINAL.captions);

function fail(message) {
  console.error(`render.mjs: ${message}`);
  process.exit(1);
}

if ((mode === "stills" || mode === "draft") && !outPath) fail(`--${mode} needs --out`);
if (outPath && !relative(docs, outPath).startsWith("..")) {
  fail("--out must be outside docs/. Only the final render (with every voice take) or --reuse-audio without --out writes the published files.");
}
if (reuse && voiceDir) fail("--reuse-audio keeps the published soundtrack; it can't be combined with --voice.");
if (reuse && mode === "draft") fail("--reuse-audio replaces --draft here: use --reuse-audio --out FILE.mp4 for a preview outside docs/.");
if (!reuse && (option("--source") || option("--captions"))) fail("--source and --captions only apply with --reuse-audio.");
if (mode === "final" && !voiceDir) {
  fail("the final video needs a voiced soundtrack: pass --voice DIR with one <id>.wav per segment, or --reuse-audio to keep the published one (see README.md). Use --draft --out FILE for a preview; a music-only draft is never published.");
}

const narration = JSON.parse(readFileSync(join(here, "narration.json"), "utf8"));

// ---------- Audio helpers ----------

function decode(file) {
  const r = spawnSync("ffmpeg", ["-v", "error", "-i", file, "-ac", "1", "-ar", String(SAMPLE_RATE), "-f", "f32le", "-"], {
    maxBuffer: 1 << 29,
  });
  if (r.status !== 0) fail(`ffmpeg couldn't read ${file}: ${r.stderr}`);
  const b = r.stdout;
  return new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
}

const db = (x) => 20 * Math.log10(Math.max(x, 1e-12));
const fromDb = (d) => Math.pow(10, d / 20);
const stereoOf = (n) => ({ L: new Float32Array(n), R: new Float32Array(n) });

// Finds where speech starts and ends in a take, trims the rest, and lists its voiced spans
// (relative to the first sound) so dictation words and captions can follow the real pacing.
function analyzeTake(samples, id) {
  const hop = Math.round(0.01 * SAMPLE_RATE);
  const frames = [];
  for (let s = 0; s + hop <= samples.length; s += hop) {
    let sum = 0;
    for (let i = s; i < s + hop; i++) sum += samples[i] * samples[i];
    frames.push(Math.sqrt(sum / hop));
  }
  const peak = Math.max(...frames);
  if (!(peak > fromDb(-50))) fail(`voice take "${id}" is silent`);
  const threshold = Math.max(peak * fromDb(-36), fromDb(-58));
  const first = frames.findIndex((v) => v > threshold);
  let last = frames.length - 1;
  while (frames[last] <= threshold) last--;
  const pre = Math.round(0.03 * SAMPLE_RATE);
  const post = Math.round(0.18 * SAMPLE_RATE);
  const s0 = Math.max(0, first * hop - pre);
  const s1 = Math.min(samples.length, (last + 1) * hop + post);
  const trimmed = samples.slice(s0, s1);
  const fadeIn = Math.round(0.008 * SAMPLE_RATE);
  const fadeOut = Math.round(0.06 * SAMPLE_RATE);
  for (let i = 0; i < fadeIn && i < trimmed.length; i++) trimmed[i] *= i / fadeIn;
  for (let i = 0; i < fadeOut && i < trimmed.length; i++) trimmed[trimmed.length - 1 - i] *= i / fadeOut;
  const onset = first * hop;
  const voiced = [];
  for (let f = first; f <= last; f++) {
    if (frames[f] <= threshold) continue;
    const a = (f * hop - onset) / SAMPLE_RATE;
    const b = ((f + 1) * hop - onset) / SAMPLE_RATE;
    const prev = voiced[voiced.length - 1];
    if (prev && a - prev[1] < 0.15) prev[1] = b;
    else voiced.push([a, b]);
  }
  return { trimmed, lead: (onset - s0) / SAMPLE_RATE, duration: ((last + 1) * hop - onset) / SAMPLE_RATE, voiced };
}

function loadVoice() {
  if (!voiceDir) return null;
  const takes = {};
  const missing = [];
  for (const s of narration.segments) {
    const file = join(voiceDir, `${s.id}.wav`);
    if (!existsSync(file)) {
      missing.push(`${s.id}.wav`);
      continue;
    }
    takes[s.id] = analyzeTake(decode(file), s.id);
  }
  if (missing.length) fail(`missing voice take(s) in ${voiceDir}: ${missing.join(", ")}`);
  return takes;
}

// ITU-R BS.1770 K-weighting at 48 kHz, then gated integrated loudness (LUFS).
function kWeight(x) {
  const stages = [
    [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585],
    [1, -2, 1, -1.99004745483398, 0.99007225036621],
  ];
  let y = x;
  for (const [b0, b1, b2, a1, a2] of stages) {
    const out = new Float32Array(y.length);
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (let i = 0; i < y.length; i++) {
      const v = b0 * y[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1; x1 = y[i]; y2 = y1; y1 = v;
      out[i] = v;
    }
    y = out;
  }
  return y;
}

function loudness(channels) {
  const weighted = channels.map(kWeight);
  const block = Math.round(0.4 * SAMPLE_RATE);
  const step = Math.round(0.1 * SAMPLE_RATE);
  const n = weighted[0].length;
  const blocks = [];
  for (let s = 0; s + block <= n; s += step) {
    let z = 0;
    for (const w of weighted) {
      let sum = 0;
      for (let i = s; i < s + block; i++) sum += w[i] * w[i];
      z += sum / block;
    }
    blocks.push(z);
  }
  const lk = (z) => -0.691 + 10 * Math.log10(z);
  let gated = blocks.filter((z) => z > 0 && lk(z) > -70);
  if (!gated.length) return -Infinity;
  const mean = (list) => list.reduce((a, b) => a + b, 0) / list.length;
  const relative = lk(mean(gated)) - 10;
  gated = gated.filter((z) => lk(z) > relative);
  return lk(mean(gated));
}

function highpass(x, cutoff) {
  const rc = 1 / (2 * Math.PI * cutoff);
  const a = rc / (rc + 1 / SAMPLE_RATE);
  const out = new Float32Array(x.length);
  let px = 0, py = 0;
  for (let i = 0; i < x.length; i++) {
    py = a * (py + x[i] - px);
    px = x[i];
    out[i] = py;
  }
  return out;
}

function lowpass(x, cutoff) {
  const a = 1 - Math.exp((-2 * Math.PI * cutoff) / SAMPLE_RATE);
  const out = new Float32Array(x.length);
  let y = 0;
  for (let i = 0; i < x.length; i++) {
    y += a * (x[i] - y);
    out[i] = y;
  }
  return out;
}

// Gentle feed-forward compressor so the narrator's level stays even under the music.
function compress(x, { threshold = -24, ratio = 2.5, attack = 0.008, release = 0.15 } = {}) {
  const out = new Float32Array(x.length);
  const ca = Math.exp(-1 / (attack * SAMPLE_RATE));
  const cr = Math.exp(-1 / (release * SAMPLE_RATE));
  let env = 0;
  for (let i = 0; i < x.length; i++) {
    const v = Math.abs(x[i]);
    env = v > env ? ca * env + (1 - ca) * v : cr * env + (1 - cr) * v;
    const over = db(env) - threshold;
    const gain = over > 0 ? fromDb(-over * (1 - 1 / ratio)) : 1;
    out[i] = x[i] * gain;
  }
  return out;
}

// Music gain that dips while anyone speaks: it starts dipping 80 ms before speech, dips over
// 60 ms and recovers over 350 ms, so the bed comes back up between lines without pumping.
function duckGain(voice, depthDb) {
  const hop = Math.round(0.01 * SAMPLE_RATE);
  const hops = Math.ceil(voice.length / hop);
  const active = new Uint8Array(hops);
  for (let h = 0; h < hops; h++) {
    let sum = 0;
    const end = Math.min(voice.length, (h + 1) * hop);
    for (let i = h * hop; i < end; i++) sum += voice[i] * voice[i];
    active[h] = Math.sqrt(sum / hop) > fromDb(-45) ? 1 : 0;
  }
  const ahead = 8;
  const gain = new Float32Array(voice.length);
  const floor = fromDb(-depthDb);
  const down = Math.exp(-1 / (0.06 * SAMPLE_RATE));
  const up = Math.exp(-1 / (0.35 * SAMPLE_RATE));
  let g = 1;
  for (let i = 0; i < voice.length; i++) {
    const h = Math.floor(i / hop);
    let speaking = 0;
    for (let k = h; k < Math.min(hops, h + ahead); k++) speaking |= active[k];
    const target = speaking ? floor : 1;
    g = target < g ? down * g + (1 - down) * target : up * g + (1 - up) * target;
    gain[i] = g;
  }
  return gain;
}

// Look-ahead peak limiter (5 ms) with a hard safety clip at the ceiling.
function limit(L, R, ceiling) {
  const n = L.length;
  const look = Math.round(0.005 * SAMPLE_RATE);
  const release = Math.exp(-1 / (0.08 * SAMPLE_RATE));
  const peakAhead = new Float32Array(n);
  const deque = [];
  const at = (i) => Math.max(Math.abs(L[i]), Math.abs(R[i]));
  for (let i = n - 1; i >= 0; i--) {
    while (deque.length && at(deque[deque.length - 1]) <= at(i)) deque.pop();
    deque.push(i);
    while (deque[0] > i + look) deque.shift();
    peakAhead[i] = at(deque[0]);
  }
  let g = 1;
  let reduced = 0;
  let deepest = 1;
  for (let i = 0; i < n; i++) {
    const target = Math.min(1, ceiling / Math.max(peakAhead[i], 1e-9));
    g = target < g ? target : release * g + (1 - release) * target;
    if (g < 0.999) reduced++;
    deepest = Math.min(deepest, g);
    L[i] = Math.max(-ceiling, Math.min(ceiling, L[i] * g));
    R[i] = Math.max(-ceiling, Math.min(ceiling, R[i] * g));
  }
  return { share: reduced / n, deepest: db(deepest) };
}

function writeWav(file, L, R) {
  const n = L.length;
  const buf = Buffer.alloc(44 + n * 8);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + n * 8, 4);
  buf.write("WAVEfmt ", 8);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(3, 20); // IEEE float
  buf.writeUInt16LE(2, 22);
  buf.writeUInt32LE(SAMPLE_RATE, 24);
  buf.writeUInt32LE(SAMPLE_RATE * 8, 28);
  buf.writeUInt16LE(8, 32);
  buf.writeUInt16LE(32, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(n * 8, 40);
  for (let i = 0; i < n; i++) {
    buf.writeFloatLE(L[i], 44 + i * 8);
    buf.writeFloatLE(R[i], 48 + i * 8);
  }
  writeFileSync(file, buf);
}

// ---------- The published video, for --reuse-audio ----------
//
// The original voice takes aren't kept in the repository, but the published MP4 carries the
// finished mix and its captions were written from the same measured timing (see captions()
// below). Each cue starts at its line's measured start, and ends 0.35 s after the line's
// last sound unless the next line (or the video's end) clips it. So the captions give every
// line's real start and length without guessing, and the audio can be copied unchanged.

const sha256File = (file) => createHash("sha256").update(readFileSync(file)).digest("hex");
const repoPath = (file) => relative(repoRoot, file) || ".";

function run(cmd, list) {
  const r = spawnSync(cmd, list, { encoding: "utf8", maxBuffer: 1 << 26 });
  if (r.error) fail(`${cmd} couldn't start: ${r.error.message}`);
  if (r.status !== 0) fail(`${cmd} failed: ${r.stderr}`);
  return r;
}

function probe(file, selector, entries) {
  const r = run("ffprobe", ["-v", "error", ...selector, "-show_entries", entries, "-of", "json", file]);
  return JSON.parse(r.stdout).streams || [];
}

function videoFrames(file) {
  const [v] = probe(file, ["-select_streams", "v:0", "-count_packets"], "stream=nb_read_packets,r_frame_rate,width,height");
  if (!v) fail(`${file} has no video stream`);
  return { frames: Number(v.nb_read_packets), rate: v.r_frame_rate, width: v.width, height: v.height };
}

// SHA-256 of the audio stream's encoded packets, independent of the container around them.
// Equal hashes before and after muxing prove the soundtrack was copied, not re-encoded.
function audioStreamHash(file) {
  const r = run("ffmpeg", ["-v", "error", "-i", file, "-map", "0:a:0", "-c", "copy", "-f", "streamhash", "-hash", "sha256", "-"]);
  const hash = r.stdout.match(/SHA256=([0-9a-f]{64})/i)?.[1];
  if (!hash) fail("couldn't hash the audio stream: ffmpeg 4.4 or later (streamhash muxer) is required");
  return hash.toLowerCase();
}

function parseVtt(text) {
  const ms = (stamp) => {
    const m = stamp.match(/^(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})$/);
    if (!m) fail(`unreadable caption time "${stamp}"`);
    return ((Number(m[1] || 0) * 60 + Number(m[2])) * 60 + Number(m[3])) * 1000 + Number(m[4]);
  };
  const cues = [];
  for (const block of text.replace(/\r/g, "").split(/\n{2,}/)) {
    const lines = block.split("\n").filter((line) => line.trim());
    const at = lines.findIndex((line) => line.includes("-->"));
    if (at < 0) continue;
    const [a, b] = lines[at].split("-->").map((part) => ms(part.trim().split(/\s+/)[0]));
    cues.push({ start: a, end: b, text: lines.slice(at + 1).join(" ") });
  }
  return cues;
}

// Every narration line, matched to its caption cue(s) word for word, with its measured
// start and length. Fails rather than estimating when a cue's end was clipped.
function timingFromCaptions(cues, durationMs) {
  const unquote = (text) => text.replace(/^“/, "").replace(/”$/, "");
  const lines = [];
  let c = 0;
  for (const s of narration.segments) {
    const parts = [];
    let joined = "";
    while (c < cues.length && joined !== s.text) {
      parts.push(cues[c++]);
      joined = parts.map((p) => (s.kind === "dictation" ? unquote(p.text) : p.text)).join(" ");
      if (joined !== s.text && !s.text.startsWith(`${joined} `)) {
        fail(`caption "${parts[parts.length - 1].text}" doesn't match narration line "${s.id}"; the published audio isn't this narration.json`);
      }
    }
    if (joined !== s.text) fail(`the captions end before narration line "${s.id}"`);
    lines.push({ id: s.id, kind: s.kind, declaredStart: s.start, startMs: parts[0].start, captionEndMs: parts[parts.length - 1].end });
  }
  if (c !== cues.length) fail(`the captions have ${cues.length - c} cue(s) beyond narration.json`);
  return lines.map((line, i) => {
    const next = lines[i + 1];
    const limit = next ? next.startMs - 50 : durationMs;
    if (line.captionEndMs >= limit - 1) {
      fail(`can't measure where "${line.id}" ends: its caption was clipped by ${next ? "the next line" : "the end of the video"}, so its length would be a guess`);
    }
    const endMs = line.captionEndMs - 350;
    if (endMs <= line.startMs || (i && line.startMs < lines[i - 1].captionEndMs - 350)) fail(`caption timing for "${line.id}" is inconsistent`);
    return { ...line, start: line.startMs / 1000, end: endMs / 1000, duration: (endMs - line.startMs) / 1000 };
  });
}

function measurePublished() {
  for (const file of [sourceVideo, sourceCaptions]) if (!existsSync(file)) fail(`--reuse-audio needs ${file}`);
  mkdirSync(workDir, { recursive: true });
  const videoSha = sha256File(sourceVideo);
  // Work from a private copy: without --out, the output replaces the published file.
  const copy = join(workDir, `source-${videoSha.slice(0, 16)}.mp4`);
  if (!existsSync(copy) || sha256File(copy) !== videoSha) copyFileSync(sourceVideo, copy);
  const streams = probe(copy, [], "stream=codec_type");
  const audioStreams = streams.filter((s) => s.codec_type === "audio").length;
  if (audioStreams !== 1) fail(`${sourceVideo} must have exactly one audio stream (found ${audioStreams})`);
  const video = videoFrames(copy);
  if (video.rate !== `${FPS}/1` || !(video.frames > 0)) fail(`${sourceVideo} is ${video.rate} with ${video.frames} frames; expected ${FPS}/1`);
  const [audio] = probe(copy, ["-select_streams", "a:0"], "stream=codec_name,sample_rate,channels");
  const durationMs = Math.round((video.frames / FPS) * 1000);
  const lines = timingFromCaptions(parseVtt(readFileSync(sourceCaptions, "utf8")), durationMs);
  return {
    copy,
    frames: video.frames,
    duration: video.frames / FPS,
    lines,
    measured: Object.fromEntries(lines.map((l) => [l.id, { start: l.start, duration: l.duration }])),
    video: { sha256: videoSha, width: video.width, height: video.height },
    captions: { sha256: sha256File(sourceCaptions) },
    audio: {
      streamSha256: audioStreamHash(copy),
      codec: audio.codec_name, sampleRate: Number(audio.sample_rate), channels: audio.channels,
    },
  };
}

// ---------- Timeline, voice stem and recorder waveform ----------

const published = reuse ? measurePublished() : null;
const takes = published ? null : loadVoice();
const timeline = published
  ? buildTimeline(narration, published.measured, { duration: published.duration })
  : buildTimeline(narration, takes || {});
const samples = Math.ceil(timeline.duration * SAMPLE_RATE);
const frameCount = Math.round(timeline.duration * FPS);
if (published && frameCount !== published.frames) fail(`timeline has ${frameCount} frames; the published video has ${published.frames}`);

function buildVoice() {
  const all = new Float32Array(samples);
  const dictation = new Float32Array(samples);
  const TARGET = -20; // LUFS per take, before the master is normalized
  for (const s of narration.segments) {
    const take = takes[s.id];
    let x = highpass(take.trimmed, s.kind === "dictation" ? 140 : 70);
    const gain = fromDb(TARGET - loudness([x]));
    x = x.map((v) => v * gain);
    if (s.kind === "dictation") {
      // Heard "in the room" by the Mac: a little darker, a little space, a touch quieter.
      const dark = lowpass(x, 7500);
      const room = reverb({ L: dark, R: dark }, SAMPLE_RATE, { room: 0.42, damp: 0.5 });
      x = dark.map((v, i) => (v + (room.L[i] + room.R[i]) * 0.5 * 0.35) * fromDb(-1.5));
    }
    const offset = Math.round((timeline.seg[s.id].start - take.lead) * SAMPLE_RATE);
    for (let i = 0; i < x.length; i++) {
      const j = offset + i;
      if (j < 0 || j >= samples) continue;
      all[j] += x[i];
      if (s.kind === "dictation") dictation[j] += x[i];
    }
  }
  return { all: compress(all), dictation };
}

// With --reuse-audio there are no separate dictation takes: the recorder waveform follows the
// published mix, but only inside each dictation line's measured span (with the same lead-in
// and tail as a trimmed take), so narration and music between lines never move it.
function publishedDictation(file) {
  const mix = decode(file);
  const out = new Float32Array(samples);
  for (const s of Object.values(timeline.seg)) {
    if (s.kind !== "dictation") continue;
    const a = Math.max(0, Math.round((s.start - 0.03) * SAMPLE_RATE));
    const b = Math.min(samples, mix.length, Math.round((s.end + 0.18) * SAMPLE_RATE));
    for (let i = a; i < b; i++) out[i] = mix[i];
  }
  return out;
}

// Recorder waveform level per video frame (0–1), from the dictation takes when present.
function waveformLevels(dictation) {
  const level = new Array(frameCount).fill(0);
  if (!dictation) {
    for (let f = 0; f < frameCount; f++) {
      const t = f / FPS;
      for (const s of Object.values(timeline.seg)) {
        if (s.kind === "dictation" && t >= s.start && t <= s.end) {
          level[f] = 0.35 + 0.65 * Math.abs(Math.sin(2 * Math.PI * 3.1 * t)) * (0.6 + 0.4 * Math.sin(2 * Math.PI * 0.9 * t));
        }
      }
    }
    return level;
  }
  const half = Math.round(SAMPLE_RATE / FPS / 2);
  const rms = [];
  for (let f = 0; f < frameCount; f++) {
    const c = Math.round((f / FPS) * SAMPLE_RATE);
    let sum = 0;
    let count = 0;
    for (let i = Math.max(0, c - half); i < Math.min(samples, c + half); i++) {
      sum += dictation[i] * dictation[i];
      count++;
    }
    rms.push(Math.sqrt(sum / Math.max(1, count)));
  }
  const active = rms.filter((v) => v > fromDb(-50)).sort((a, b) => a - b);
  const ref = active.length ? active[Math.floor(active.length * 0.9)] : 1;
  let smooth = 0;
  for (let f = 0; f < frameCount; f++) {
    const target = Math.min(1, rms[f] / ref);
    smooth = target > smooth ? target : smooth * 0.72 + target * 0.28;
    level[f] = Number(smooth.toFixed(3));
  }
  return level;
}

// ---------- Captions ----------

const stamp = (t) => {
  const ms = Math.max(0, Math.round(t * 1000));
  const h = String(Math.floor(ms / 3600000)).padStart(2, "0");
  const m = String(Math.floor((ms % 3600000) / 60000)).padStart(2, "0");
  const s = String(Math.floor((ms % 60000) / 1000)).padStart(2, "0");
  return `${h}:${m}:${s}.${String(ms % 1000).padStart(3, "0")}`;
};

// One cue per line; a long line splits at the comma nearest its middle. The split lands in the
// take's pause nearest that comma's share of the voiced time, so the halves never overlap.
// Dictation is quoted, because it's what the demo user says to the Mac.
function captions() {
  const segs = narration.segments.map((s) => timeline.seg[s.id]);
  const cues = [];
  segs.forEach((s, i) => {
    const next = segs[i + 1];
    const end = Math.min(s.end + 0.35, next ? next.start - 0.05 : timeline.duration);
    const quote = (text) => (s.kind === "dictation" ? `“${text}”` : text);
    const commas = [...s.text.matchAll(/, /g)].map((m) => m.index + 1);
    if (s.text.length <= 60 || !commas.length) {
      cues.push(`${stamp(s.start)} --> ${stamp(end)}\n${quote(s.text)}`);
      return;
    }
    const cut = commas.reduce((best, c) => (Math.abs(c - s.text.length / 2) < Math.abs(best - s.text.length / 2) ? c : best));
    const voicedTotal = s.voiced.reduce((sum, [a, b]) => sum + (b - a), 0);
    let remaining = (cut / s.text.length) * voicedTotal;
    let estimate = s.duration;
    for (const [a, b] of s.voiced) {
      if (remaining <= b - a) {
        estimate = a + remaining;
        break;
      }
      remaining -= b - a;
    }
    const pauses = s.voiced.slice(1).map(([a], k) => (s.voiced[k][1] + a) / 2);
    const split = s.start + (pauses.length ? pauses.reduce((best, p) => (Math.abs(p - estimate) < Math.abs(best - estimate) ? p : best)) : estimate);
    cues.push(`${stamp(s.start)} --> ${stamp(split)}\n${quote(s.text.slice(0, cut))}`);
    cues.push(`${stamp(split)} --> ${stamp(end)}\n${quote(s.text.slice(cut + 1))}`);
  });
  return `WEBVTT\n\n${cues.map((c, i) => `${i + 1}\n${c}`).join("\n\n")}\n`;
}

// ---------- Picture ----------

async function openScene(browser, promo, scale) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
  await page.addInitScript(`window.PROMO = ${JSON.stringify(promo)};`);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(pathToFileURL(join(here, "scene.html")).href);
  await page.waitForFunction(() => window.promoReady === true || window.promoFailed, null, { timeout: 15000 }).catch(() => {});
  if (errors.length) fail(`scene.html failed: ${errors.join("; ")}`);
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map((img) => img.decode().catch(() => {})));
  });
  return page;
}

async function renderPicture(browser, promo, file) {
  const page = await openScene(browser, promo, deviceScale);
  // H.264 High, yuv420p and +faststart so every browser can start playback before the whole
  // file downloads. -tune animation suits flat motion graphics.
  const ffmpeg = spawn(
    "ffmpeg",
    [
      "-y", "-loglevel", "error",
      "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "png", "-i", "-",
      "-vf", "scale=1920:1080:flags=lanczos",
      "-c:v", "libx264", "-preset", "slow", "-tune", "animation", "-crf", "19",
      "-profile:v", "high", "-level", "4.1", "-pix_fmt", "yuv420p", "-an",
      file,
    ],
    { stdio: ["pipe", "inherit", "inherit"] },
  );
  const done = new Promise((ok, no) => {
    ffmpeg.on("error", no);
    ffmpeg.on("close", (code) => (code === 0 ? ok() : no(new Error(`ffmpeg exited ${code}`))));
  });
  for (let f = 0; f < frameCount; f++) {
    await page.evaluate((t) => window.renderAt(t), f / FPS);
    const png = await page.screenshot({ type: "png" });
    if (!ffmpeg.stdin.write(png)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
    if (f % 150 === 0) console.log(`frame ${f}/${frameCount}`);
  }
  ffmpeg.stdin.end();
  await done;
  await page.close();
}

// ---------- Modes ----------

function printPlan() {
  const rows = narration.segments.map((s, i) => {
    const next = narration.segments[i + 1];
    const budget = (next ? next.start : narration.duration - 1) - narration.minGap - s.start;
    const seg = timeline.seg[s.id];
    const length = seg.duration.toFixed(2) + (seg.measured ? " s" : " s (estimate)");
    const moved = Math.abs(seg.start - s.start) > 1e-6 ? ` → starts ${seg.start.toFixed(2)}` : "";
    return `${s.id.padEnd(11)} ${s.kind.padEnd(9)} ${s.start.toFixed(2).padStart(5)}  budget ${budget.toFixed(2)} s  take ${length}${seg.duration > budget + 1e-6 ? "  OVER" : ""}${moved}`;
  });
  console.log(rows.join("\n"));
  console.log(`duration ${timeline.duration.toFixed(2)} s at ${narration.bpm} bpm`);
  if (timeline.shifts.length) console.log(`shifted: ${timeline.shifts.map((s) => `${s.id} ${s.by > 0 ? "+" : ""}${s.by} s`).join(", ")}`);
  if (published) {
    console.log(`timing measured from ${repoPath(sourceCaptions)}; ${published.frames} frames from ${repoPath(sourceVideo)}`);
    console.log(`audio stream sha256 ${published.audio.streamSha256} (${published.audio.codec}, ${published.audio.sampleRate} Hz, ${published.audio.channels} ch)`);
    console.log("dictation words are placed by syllable within each measured line, not per measured word");
  }
}

// The provenance file. Records hashes only; no dates, so identical inputs give identical bytes.
function receiptFor(kind, extra) {
  const files = ["scene.html", "timeline.mjs", "render.mjs", "music.mjs", "narration.json"];
  return {
    about: "Provenance of the published promo video. Written by render.mjs; see promo/README.md.",
    kind,
    narration: { segments: narration.segments.map((s) => s.id), duration: timeline.duration, fps: FPS, frames: frameCount },
    picture: {
      sources: Object.fromEntries(files.map((f) => [f, sha256File(join(here, f))])),
      deviceScale,
    },
    ...extra,
  };
}

// --reuse-audio: mux the rendered picture with the published audio packets, verify, then
// publish (or write the preview). The soundtrack and captions are never regenerated.
async function finishReuse(browser, promo, picture) {
  const target = outPath || FINAL.video;
  const base = target.slice(0, target.length - extname(target).length);
  const captionsFile = outPath ? `${base}.vtt` : FINAL.captions;
  const posterFile = outPath ? `${base}-poster.jpg` : FINAL.poster;
  const receiptFile = outPath ? `${base}.receipt.json` : RECEIPT;

  // Once a soundtrack is recorded, only those exact audio packets may be reused.
  if (existsSync(RECEIPT)) {
    const recorded = JSON.parse(readFileSync(RECEIPT, "utf8")).audio?.streamSha256;
    if (recorded && recorded !== published.audio.streamSha256) {
      fail(`${repoPath(sourceVideo)} carries audio ${published.audio.streamSha256}, not the soundtrack recorded in ${repoPath(RECEIPT)} (${recorded}). Refusing to publish a different soundtrack.`);
    }
  }

  // Mux in the work folder; nothing reaches the target until the result verifies.
  const candidate = join(workDir, "reuse-candidate.mp4");
  run("ffmpeg", [
    "-y", "-loglevel", "error", "-i", picture, "-i", published.copy,
    "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-movflags", "+faststart", candidate,
  ]);
  const made = videoFrames(candidate);
  if (made.frames !== published.frames || made.rate !== `${FPS}/1`) {
    fail(`the new video has ${made.frames} frames at ${made.rate}; the published one has ${published.frames} at ${FPS}/1`);
  }
  const outAudio = audioStreamHash(candidate);
  if (outAudio !== published.audio.streamSha256) fail("the muxed audio isn't packet-identical to the published soundtrack");

  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(candidate, target);
  // The captions describe this exact audio, so they are kept byte for byte.
  if (resolve(captionsFile) !== sourceCaptions) copyFileSync(sourceCaptions, captionsFile);
  if (sha256File(captionsFile) !== published.captions.sha256) fail(`${captionsFile} changed while rendering`);

  const posterPage = await openScene(browser, promo, 1);
  await posterPage.evaluate((t) => window.renderAt(t), timeline.moments.typeEnd + 0.15);
  await posterPage.screenshot({ path: posterFile, type: "jpeg", quality: 86 });

  const receipt = receiptFor("reuse-audio", {
    audio: {
      streamSha256: outAudio,
      codec: published.audio.codec, sampleRate: published.audio.sampleRate, channels: published.audio.channels,
      reusedFrom: { file: repoPath(sourceVideo), sha256: published.video.sha256 },
      voiceTakes: "not used: the published soundtrack (voice, music and interface sounds) is copied unchanged",
    },
    timing: {
      from: { captions: repoPath(sourceCaptions), sha256: published.captions.sha256 },
      lines: published.lines.map((l) => ({ id: l.id, kind: l.kind, declaredStart: l.declaredStart, start: l.start, end: l.end })),
      dictationWords: "placed by syllable within each measured line",
      waveform: "published mix inside the measured dictation lines",
    },
    output: {
      video: { file: repoPath(target), sha256: sha256File(target) },
      captions: { file: repoPath(captionsFile), sha256: published.captions.sha256 },
      poster: { file: repoPath(posterFile), sha256: sha256File(posterFile) },
      chrome: browser.version(),
    },
  });
  writeFileSync(receiptFile, `${JSON.stringify(receipt, null, 2)}\n`);

  const measured = measureFile(target);
  console.log(target);
  console.log(captionsFile);
  console.log(posterFile);
  console.log(receiptFile);
  console.log(`audio packets identical to the published soundtrack (sha256 ${outAudio})`);
  console.log(`loudness ${measured.integrated} LUFS, true peak ${measured.truePeak} dBFS, ${timeline.duration.toFixed(2)} s, ${made.frames} frames`);
}

function measureFile(file) {
  const r = run("ffmpeg", ["-hide_banner", "-nostats", "-i", file, "-af", "ebur128=peak=true", "-f", "null", "-"]);
  const summary = r.stderr.slice(r.stderr.lastIndexOf("Summary:"));
  const I = summary.match(/I:\s+(-?[\d.]+) LUFS/)?.[1];
  const peak = summary.match(/Peak:\s+(-?[\d.]+) dBFS/)?.[1];
  return { integrated: Number(I), truePeak: Number(peak) };
}

async function main() {
  if (timeline.shifts.length) {
    console.warn(published
      ? `note: the published audio starts these lines away from narration.json, and the picture follows it: ${timeline.shifts.map((s) => `${s.id} ${s.by > 0 ? "+" : ""}${s.by} s`).join(", ")}`
      : `note: long take(s) moved later lines by whole beats: ${timeline.shifts.map((s) => `${s.id} +${s.by} s`).join(", ")}`);
  }
  if (mode === "plan") return printPlan();

  const voice = takes ? buildVoice() : null;
  const promo = { ...timeline, level: waveformLevels(published ? publishedDictation(published.copy) : voice?.dictation) };
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  try {
    if (mode === "stills") {
      mkdirSync(outPath, { recursive: true });
      const m = timeline.moments;
      const moments = times.length ? times : [
        2.4, m.hudIn + 2.4, m.dragEnd, m.selLand + 0.15, m.shotEnd, m.shotLand + 0.1,
        m.typeEnd + 0.15, m.dockClick + 0.6, m.sendAt + 0.9, m.detailsClick + 0.5,
        m.scrollEnd + 0.3, m.endDetails + 1,
      ];
      const page = await openScene(browser, promo, deviceScale);
      for (const t of moments) {
        const file = join(outPath, `still-${t.toFixed(2)}.png`);
        await page.evaluate((s) => window.renderAt(s), t);
        await page.screenshot({ path: file });
        console.log(file);
      }
      return;
    }

    // Picture, cached by everything that affects it.
    mkdirSync(workDir, { recursive: true });
    const key = createHash("sha256")
      .update(readFileSync(join(here, "scene.html")))
      .update(JSON.stringify(promo))
      .update(String(deviceScale))
      .digest("hex")
      .slice(0, 16);
    const picture = join(workDir, `picture-${key}.mp4`);
    if (fresh || !existsSync(picture)) await renderPicture(browser, promo, picture);
    else console.log(`reusing ${picture}`);

    if (mode === "reuse") return await finishReuse(browser, promo, picture);

    // Sound: music and interface sounds, with the voice on top when there is one.
    const { music, sfx } = renderSoundtrack(timeline);
    const L = new Float32Array(samples);
    const R = new Float32Array(samples);
    const musicLevel = loudness([music.L, music.R]);
    let musicGain;
    let sfxGain;
    const stems = { music: stereoOf(samples), sfx: stereoOf(samples) };
    if (voice) {
      // Music sits 6 LU under the voice between lines and dips 6 dB more under speech, so it
      // is clearly there without competing with the words.
      const voiceLevel = loudness([voice.all, voice.all]);
      musicGain = fromDb(voiceLevel - 6 - musicLevel);
      sfxGain = musicGain * 0.8;
      const duck = duckGain(voice.all, 6);
      for (let i = 0; i < samples; i++) {
        stems.music.L[i] = music.L[i] * musicGain * duck[i];
        stems.music.R[i] = music.R[i] * musicGain * duck[i];
        stems.sfx.L[i] = sfx.L[i] * sfxGain;
        stems.sfx.R[i] = sfx.R[i] * sfxGain;
        L[i] = voice.all[i] + stems.music.L[i] + stems.sfx.L[i];
        R[i] = voice.all[i] + stems.music.R[i] + stems.sfx.R[i];
      }
    } else {
      musicGain = 1;
      sfxGain = 0.8;
      for (let i = 0; i < samples; i++) {
        stems.music.L[i] = music.L[i];
        stems.music.R[i] = music.R[i];
        stems.sfx.L[i] = sfx.L[i] * sfxGain;
        stems.sfx.R[i] = sfx.R[i] * sfxGain;
        L[i] = stems.music.L[i] + stems.sfx.L[i];
        R[i] = stems.music.R[i] + stems.sfx.R[i];
      }
    }
    // Master: -16 LUFS integrated, peaks held under -2 dBFS (about -1.5 dBTP after AAC).
    const ceiling = fromDb(-2);
    let masterGain = 1;
    for (let pass = 0; pass < 2; pass++) {
      const g = fromDb(-16 - loudness([L, R]));
      masterGain *= g;
      for (let i = 0; i < samples; i++) {
        L[i] *= g;
        R[i] *= g;
      }
      const limited = limit(L, R, ceiling);
      if (pass === 1) {
        console.log(`master: limiter active on ${(limited.share * 100).toFixed(2)}% of samples, at most ${limited.deepest.toFixed(1)} dB`);
      }
    }
    const master = join(workDir, "master.wav");
    writeWav(master, L, R);
    // Stems at their level in the master (before limiting), for checking the balance.
    const scaled = (x) => x.map((v) => v * masterGain);
    if (voice) writeWav(join(workDir, "stem-voice.wav"), scaled(voice.all), scaled(voice.all));
    writeWav(join(workDir, "stem-music.wav"), scaled(stems.music.L), scaled(stems.music.R));
    writeWav(join(workDir, "stem-sfx.wav"), scaled(stems.sfx.L), scaled(stems.sfx.R));

    const target = mode === "final" ? FINAL.video : outPath;
    const captionsFile = mode === "final" ? FINAL.captions : target.replace(new RegExp(`${extname(target)}$`), ".vtt");
    const posterFile = mode === "final" ? FINAL.poster : target.replace(new RegExp(`${extname(target)}$`), "-poster.jpg");
    mkdirSync(dirname(target), { recursive: true });
    const aac = spawnSync("ffmpeg", ["-hide_banner", "-encoders"], { encoding: "utf8" }).stdout.includes("aac_at") ? "aac_at" : "aac";
    run("ffmpeg", [
      "-y", "-loglevel", "error", "-i", picture, "-i", master,
      "-map", "0:v", "-map", "1:a", "-c:v", "copy",
      "-c:a", aac, "-b:a", "192k", "-ar", String(SAMPLE_RATE), "-ac", "2",
      "-t", String(timeline.duration), "-movflags", "+faststart", target,
    ]);
    writeFileSync(captionsFile, captions());

    // Poster at 1× so the JPEG stays small: the recorder holds the spoken words, both
    // references and the name being typed, which explains the product in one frame.
    const posterPage = await openScene(browser, promo, 1);
    await posterPage.evaluate((t) => window.renderAt(t), timeline.moments.typeEnd + 0.15);
    await posterPage.screenshot({ path: posterFile, type: "jpeg", quality: 86 });

    if (mode === "final") {
      // A new voiced soundtrack becomes the one later --reuse-audio renders must keep.
      writeFileSync(RECEIPT, `${JSON.stringify(receiptFor("voice-takes", {
        audio: {
          streamSha256: audioStreamHash(target),
          voiceTakes: Object.fromEntries(narration.segments.map((s) => [`${s.id}.wav`, sha256File(join(voiceDir, `${s.id}.wav`))])),
        },
        output: {
          video: { file: repoPath(target), sha256: sha256File(target) },
          captions: { file: repoPath(captionsFile), sha256: sha256File(captionsFile) },
          poster: { file: repoPath(posterFile), sha256: sha256File(posterFile) },
          chrome: browser.version(),
        },
      }), null, 2)}\n`);
      console.log(RECEIPT);
    }

    const measured = measureFile(target);
    console.log(target);
    console.log(captionsFile);
    console.log(posterFile);
    console.log(`loudness ${measured.integrated} LUFS, true peak ${measured.truePeak} dBFS, ${timeline.duration.toFixed(2)} s`);
  } finally {
    await browser.close();
  }
}

await main();
