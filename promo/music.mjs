// Original music bed and interface sounds for the promo, synthesized from code.
//
// Nothing here is sampled or licensed: every sound is an oscillator, filtered noise or a
// simple physical-ish model, and the random sources are seeded, so each render is identical.
// The arrangement follows the shared timeline (timeline.mjs): the groove starts with the
// recorder, drops out at the stop, lifts into the paste and resolves on the end card.
//
// renderSoundtrack(timeline) returns two stereo buses at 48 kHz: `music` (ducked under the
// voice by render.mjs) and `sfx` (interface sounds, never ducked). Levels inside each bus are
// balanced here; render.mjs sets the bus levels against the voice.

const TAU = Math.PI * 2;
const hz = (midi) => 440 * Math.pow(2, (midi - 69) / 12);

// mulberry32: small, fast, deterministic.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function stereo(n) {
  return { L: new Float32Array(n), R: new Float32Array(n) };
}

// Equal-power pan, -1 (left) … 1 (right).
function panGains(pan) {
  const a = ((pan + 1) * Math.PI) / 4;
  return [Math.cos(a), Math.sin(a)];
}

// Band-limited sawtooth correction.
function polyblep(p, dt) {
  if (p < dt) {
    const x = p / dt;
    return x + x - x * x - 1;
  }
  if (p > 1 - dt) {
    const x = (p - 1) / dt;
    return x * x + x + x + 1;
  }
  return 0;
}

// Topology-preserving state-variable filter (Zavalishin). Returns lowpass, bandpass, highpass.
class SVF {
  constructor() {
    this.ic1 = 0;
    this.ic2 = 0;
  }

  run(x, cutoff, q, sampleRate) {
    const g = Math.tan((Math.PI * Math.min(cutoff, sampleRate * 0.45)) / sampleRate);
    const k = 1 / q;
    const a1 = 1 / (1 + g * (g + k));
    const a2 = g * a1;
    const a3 = g * a2;
    const v3 = x - this.ic2;
    const v1 = a1 * this.ic1 + a2 * v3;
    const v2 = this.ic2 + a2 * this.ic1 + a3 * v3;
    this.ic1 = 2 * v1 - this.ic1;
    this.ic2 = 2 * v2 - this.ic2;
    this.lp = v2;
    this.bp = v1;
    this.hp = x - k * v1 - v2;
    return v2;
  }
}

// Freeverb (Jezar's public-domain design), stereo in, stereo wet out.
export function reverb(input, sampleRate, { room = 0.84, damp = 0.3, wet = 1 } = {}) {
  const scale = sampleRate / 44100;
  const combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
  const allpasses = [556, 441, 341, 225];
  const spread = 23;
  const n = input.L.length;
  const out = stereo(n);
  for (const [channel, offset] of [["L", 0], ["R", spread]]) {
    const cb = combs.map((len) => ({ buf: new Float32Array(Math.round((len + offset) * scale)), i: 0, store: 0 }));
    const ab = allpasses.map((len) => ({ buf: new Float32Array(Math.round((len + offset) * scale)), i: 0 }));
    const dst = out[channel];
    for (let s = 0; s < n; s++) {
      const x = (input.L[s] + input.R[s]) * 0.015;
      let y = 0;
      for (const c of cb) {
        const o = c.buf[c.i];
        c.store = o * (1 - damp) + c.store * damp;
        c.buf[c.i] = x + c.store * room;
        if (++c.i >= c.buf.length) c.i = 0;
        y += o;
      }
      for (const a of ab) {
        const o = a.buf[a.i];
        a.buf[a.i] = y + o * 0.5;
        if (++a.i >= a.buf.length) a.i = 0;
        y = o - y;
      }
      dst[s] = y * wet;
    }
  }
  return out;
}

function mixInto(dst, src, gain = 1) {
  for (let i = 0; i < dst.L.length; i++) {
    dst.L[i] += src.L[i] * gain;
    dst.R[i] += src.R[i] * gain;
  }
}

// ---------- Harmony: D major, one chord per bar ----------

// pad: sustained voicing; bass: sub root; arp: pluck tones (low to high).
const CHORDS = {
  D: { pad: [50, 57, 61, 64, 66], bass: 38, arp: [74, 76, 78, 81, 85] },          // Dmaj9
  Bm: { pad: [47, 54, 57, 62, 64], bass: 35, arp: [71, 74, 76, 78, 81] },         // Bm11
  G: { pad: [43, 54, 57, 59, 61], bass: 31, arp: [71, 74, 78, 81, 85] },          // Gmaj9(#11)
  A: { pad: [45, 52, 57, 59, 62], bass: 33, arp: [69, 71, 74, 76, 81],            // Asus4 …
       padLate: [45, 52, 57, 59, 61], arpLate: [69, 73, 76, 79, 81] },            // … → A7
};
const LOOP = ["D", "Bm", "G", "A"];

// 16-step arpeggio pattern (indices into the chord's arp tones) and accents.
const ARP_STEPS = [0, 2, 4, 2, 1, 3, 4, 3, 0, 2, 4, 3, 1, 3, 2, 1];
const ARP_ACCENT = [1, 0.55, 0.7, 0.5, 0.85, 0.5, 0.7, 0.5, 0.95, 0.55, 0.7, 0.5, 0.85, 0.5, 0.65, 0.5];

export function renderSoundtrack(tl) {
  const sr = tl.sampleRate;
  const n = Math.ceil(tl.duration * sr);
  const beat = tl.beat;
  const bar = beat * 4;
  const m = tl.moments;
  const at = (seconds) => Math.max(0, Math.min(n, Math.round(seconds * sr)));
  const nearestBar = (seconds) => Math.round(seconds / bar) * bar;

  const grooveIn = nearestBar(m.hudIn);          // bar 2 by default: the recorder is up
  const breakAt = m.stop;                         // drums out on the stop press
  const dropAt = m.pasteLand;                     // and back in on the paste
  const endBar = Math.ceil(m.endIn / bar - 1e-9); // plagal close: IV, then I to the end
  const finalAt = (endBar + 1) * bar;
  const bars = Math.ceil(tl.duration / bar) + 1;

  const chordAt = (b) => (b >= endBar + 1 ? "D" : b === endBar ? "G" : LOOP[((b % 4) + 4) % 4]);

  const pad = stereo(n);
  const arp = stereo(n);
  const low = stereo(n);
  const drums = stereo(n);
  const sfx = stereo(n);
  const send = stereo(n); // reverb send

  // ---------- Pad: three detuned saws per note through one slowly opening filter ----------
  const detunes = [-0.07, 0, 0.07]; // semitones
  const pans = [-0.55, 0, 0.55];
  for (let b = 0; b < bars; b++) {
    const name = chordAt(b);
    const chord = CHORDS[name];
    const t0 = b * bar;
    const final = b >= endBar + 1;
    const t1 = final ? tl.duration : t0 + bar;
    const halves = chord.padLate && !final ? [[t0, t0 + bar / 2, chord.pad], [t0 + bar / 2, t1, chord.padLate]] : [[t0, t1, chord.pad]];
    for (const [a, z, notes] of halves) {
      const attack = b === 0 && a === 0 ? 0.9 : 0.35;
      const release = 0.9;
      const s0 = at(a);
      const s1 = at(z + release);
      notes.forEach((note, ni) => {
        detunes.forEach((d, vi) => {
          const f = hz(note + d);
          const dt = f / sr;
          let p = (ni * 0.21 + vi * 0.37) % 1;
          const [gl, gr] = panGains(pans[vi] * 0.9);
          const amp = 0.045 * (note < 48 ? 0.8 : 1);
          for (let s = s0; s < s1; s++) {
            const time = s / sr;
            let env = Math.min(1, (time - a) / attack);
            if (time > z) env *= Math.max(0, 1 - (time - z) / release);
            if (env <= 0) continue;
            const v = (2 * p - 1 - polyblep(p, dt)) * amp * env;
            pad.L[s] += v * gl;
            pad.R[s] += v * gr;
            p += dt;
            if (p >= 1) p -= 1;
          }
        });
      });
    }
  }
  // Filter the pad: darker for the title, opening with the demo, brightest after the paste.
  // A 100 Hz high-pass keeps its low notes out of the narrator's range and the bass's way.
  const padFilter = [new SVF(), new SVF()];
  const padLow = [new SVF(), new SVF()];
  for (let s = 0; s < n; s++) {
    const time = s / sr;
    const open = 0.5 + 0.25 * Math.min(1, time / grooveIn) + 0.25 * Math.min(1, Math.max(0, (time - dropAt) / 1.5));
    const cutoff = 600 + 3400 * open * (0.85 + 0.15 * Math.sin(TAU * 0.11 * time));
    padLow[0].run(padFilter[0].run(pad.L[s], cutoff, 0.8, sr), 100, 0.7, sr);
    padLow[1].run(padFilter[1].run(pad.R[s], cutoff, 0.8, sr), 100, 0.7, sr);
    pad.L[s] = padLow[0].hp;
    pad.R[s] = padLow[1].hp;
    send.L[s] += pad.L[s] * 0.45;
    send.R[s] += pad.R[s] * 0.45;
  }

  // ---------- Plucked arpeggio with a ping-pong echo ----------
  const pluck = (time, note, vel, pan) => {
    const f = hz(note);
    const s0 = at(time);
    const s1 = Math.min(n, s0 + Math.round(0.5 * sr));
    const [gl, gr] = panGains(pan);
    for (let s = s0; s < s1; s++) {
      const x = (s - s0) / sr;
      const env = Math.min(1, x / 0.003) * Math.exp(-x / 0.16);
      const v = (Math.sin(TAU * f * x) + 0.3 * Math.sin(TAU * 2 * f * x) * Math.exp(-x / 0.05) + 0.08 * Math.sin(TAU * 3 * f * x)) * env * vel * 0.07;
      arp.L[s] += v * gl;
      arp.R[s] += v * gr;
    }
  };
  const arpStart = bar / 2; // enters softly under the title
  const arpStop = finalAt;
  const step = beat / 4;
  for (let i = Math.floor(arpStart / step); i * step < arpStop; i++) {
    const time = i * step;
    const b = Math.floor(time / bar + 1e-9);
    const chord = CHORDS[chordAt(b)];
    const late = chord.arpLate && time - b * bar >= bar / 2;
    const tones = late ? chord.arpLate : chord.arp;
    const k = i % 16;
    const intro = time < grooveIn;
    if (intro && k % 2 === 1) continue; // eighths before the groove
    if (time >= m.endIn && k % 2 === 1) continue; // eighths again as it winds down
    let vel = ARP_ACCENT[k] * (intro ? 0.55 * Math.min(1, (time - arpStart) / bar + 0.3) : 1);
    if (time >= breakAt && time < dropAt) vel *= 0.7;
    pluck(time, tones[ARP_STEPS[k]], vel, k % 4 < 2 ? -0.3 : 0.3);
  }
  // Final chord: one soft roll, low to high.
  CHORDS.D.arp.forEach((note, i) => pluck(finalAt + i * 0.07, note, 0.9 - i * 0.08, -0.4 + i * 0.2));
  // Dotted-eighth ping-pong echo, darker on each repeat.
  {
    const d = Math.round(beat * 0.75 * sr);
    const bufL = new Float32Array(d);
    const bufR = new Float32Array(d);
    const lpL = new SVF();
    const lpR = new SVF();
    let i = 0;
    for (let s = 0; s < n; s++) {
      const eL = bufL[i];
      const eR = bufR[i];
      bufL[i] = lpL.run(arp.L[s] + eR * 0.38, 3200, 0.7, sr);
      bufR[i] = lpR.run(arp.R[s] * 0.2 + eL * 0.38, 3200, 0.7, sr);
      if (++i >= d) i = 0;
      arp.L[s] += eL * 0.5;
      arp.R[s] += eR * 0.5;
      send.L[s] += arp.L[s] * 0.35;
      send.R[s] += arp.R[s] * 0.35;
    }
  }

  // ---------- Sub bass and drums ----------
  const kicks = [];
  const grooveOn = (time) => time >= grooveIn && time < m.endIn && !(time >= breakAt && time < dropAt);
  for (let i = Math.round(grooveIn / beat); i * beat < m.endIn; i += 2) {
    if (grooveOn(i * beat)) kicks.push(i * beat);
  }
  // The paste always gets a kick, even when it falls between the regular ones.
  if (!kicks.some((k) => Math.abs(k - dropAt) < 0.01)) kicks.push(dropAt);
  kicks.sort((a, b) => a - b);
  kicks.push(finalAt);
  const kickDuck = (time) => {
    let g = 1;
    for (const k of kicks) {
      if (time >= k && time < k + 0.3) g = Math.min(g, 1 - 0.45 * Math.exp(-(time - k) / 0.1));
    }
    return g;
  };

  // Sub bass: chord roots (49–73 Hz) while the groove plays, then the final root. A little
  // second harmonic lets laptop speakers suggest the bass line without muddying the voice.
  for (let b = 0; b < bars; b++) {
    const t0 = b * bar;
    const t1 = b >= endBar + 1 ? tl.duration : t0 + bar;
    if (t1 <= grooveIn || (t0 >= m.endIn && b < endBar + 1)) continue;
    const f = hz(CHORDS[chordAt(b)].bass);
    const a = Math.max(t0, grooveIn);
    for (let s = at(a); s < at(t1); s++) {
      const time = s / sr;
      if (time >= breakAt && time < dropAt) continue;
      const env = Math.min(1, (time - a) / 0.06) * Math.min(1, (t1 - time) / 0.08);
      const v = (Math.sin(TAU * f * time) + 0.25 * Math.sin(TAU * 2 * f * time)) * 0.08 * env * kickDuck(time);
      low.L[s] += v;
      low.R[s] += v;
    }
  }

  const noise = rng(20260926);
  const kick = (time, gain) => {
    const s0 = at(time);
    let phase = 0;
    for (let s = s0; s < Math.min(n, s0 + Math.round(0.45 * sr)); s++) {
      const x = (s - s0) / sr;
      phase += (TAU * (48 + 95 * Math.exp(-x / 0.03))) / sr;
      const v = Math.sin(phase) * Math.exp(-x / 0.22) * Math.min(1, x / 0.002) * gain;
      drums.L[s] += v;
      drums.R[s] += v;
    }
  };
  const hat = (time, gain, pan) => {
    const s0 = at(time);
    const f = new SVF();
    const [gl, gr] = panGains(pan);
    for (let s = s0; s < Math.min(n, s0 + Math.round(0.12 * sr)); s++) {
      const x = (s - s0) / sr;
      f.run(noise() * 2 - 1, 8200, 0.9, sr);
      const v = f.hp * Math.exp(-x / 0.028) * gain;
      drums.L[s] += v * gl;
      drums.R[s] += v * gr;
    }
  };
  const rim = (time, gain) => {
    const s0 = at(time);
    const f = new SVF();
    for (let s = s0; s < Math.min(n, s0 + Math.round(0.2 * sr)); s++) {
      const x = (s - s0) / sr;
      f.run(noise() * 2 - 1, 1900, 2.2, sr);
      const v = (f.bp * 1.4 + Math.sin(TAU * 820 * x) * 0.25) * Math.exp(-x / 0.045) * gain;
      drums.L[s] += v * 0.8;
      drums.R[s] += v;
      send.L[s] += v * 0.2;
      send.R[s] += v * 0.2;
    }
  };
  kicks.forEach((k) => kick(k, k === finalAt ? 0.22 : 0.25));
  for (let i = Math.round(grooveIn / beat); i * beat < m.endIn; i++) {
    const time = i * beat;
    if (!grooveOn(time)) continue;
    hat(time + beat / 2, 0.075, 0.25);
    if (time >= grooveIn + bar) hat(time + beat * 0.75, 0.03, -0.25);
    if (i % 2 === 1 && time >= grooveIn + 2 * bar) rim(time, 0.06);
  }

  // Lift into the paste: a noise swell rising from the stop, cut off exactly on the paste.
  {
    const f = new SVF();
    const s0 = at(breakAt);
    const s1 = at(dropAt);
    for (let s = s0; s < s1; s++) {
      const k = (s - s0) / Math.max(1, s1 - s0);
      f.run(noise() * 2 - 1, 500 + 6500 * k * k, 1.4, sr);
      const v = f.bp * k * k * 0.16;
      const [gl, gr] = panGains(-0.6 + 1.2 * k);
      drums.L[s] += v * gl;
      drums.R[s] += v * gr;
      send.L[s] += v * 0.3;
      send.R[s] += v * 0.3;
    }
  }

  // ---------- Music bus: dry parts plus one shared reverb, then a gentle glue ----------
  const music = stereo(n);
  mixInto(music, pad, 1);
  mixInto(music, arp, 1);
  mixInto(music, low, 1);
  mixInto(music, drums, 1);
  mixInto(music, reverb(send, sr, { room: 0.86, damp: 0.35 }), 0.9);
  for (let s = 0; s < n; s++) {
    const time = s / sr;
    // Fade in over the first half second and out over the last 1.8 s.
    const fade = Math.min(1, time / 0.5) * Math.min(1, Math.max(0, (tl.duration - time) / 1.8));
    music.L[s] = Math.tanh(music.L[s] * 1.2) * fade;
    music.R[s] = Math.tanh(music.R[s] * 1.2) * fade;
  }

  // ---------- Interface sounds ----------
  const sfxSend = stereo(n);
  const tick = (time, pitch, gain, pan = 0) => {
    const s0 = at(time);
    const f = new SVF();
    const [gl, gr] = panGains(pan);
    for (let s = s0; s < Math.min(n, s0 + Math.round(0.08 * sr)); s++) {
      const x = (s - s0) / sr;
      f.run(noise() * 2 - 1, 3500, 1.2, sr);
      const v = (Math.sin(TAU * pitch * x) * Math.exp(-x / 0.018) + f.bp * 0.6 * Math.exp(-x / 0.004)) * gain;
      sfx.L[s] += v * gl;
      sfx.R[s] += v * gr;
    }
  };
  // A small glassy chime, tuned to the key (A and E).
  const chime = (time, gain, pan) => {
    const [gl, gr] = panGains(pan);
    for (const [note, g, delay] of [[81, 1, 0], [88, 0.7, 0.06]]) {
      const f = hz(note);
      const s0 = at(time + delay);
      for (let s = s0; s < Math.min(n, s0 + Math.round(1.2 * sr)); s++) {
        const x = (s - s0) / sr;
        const env = Math.min(1, x / 0.004);
        const v = (Math.sin(TAU * f * x) * Math.exp(-x / 0.4) + 0.25 * Math.sin(TAU * f * 2.76 * x) * Math.exp(-x / 0.09)) * env * g * gain;
        sfx.L[s] += v * gl;
        sfx.R[s] += v * gr;
        sfxSend.L[s] += v * gl * 0.6;
        sfxSend.R[s] += v * gr * 0.6;
      }
    }
  };
  // Soft camera shutter: two short filtered clicks.
  const shutter = (time, gain) => {
    for (const [offset, centre, len] of [[0, 3200, 0.03], [0.075, 2100, 0.045]]) {
      const f = new SVF();
      const s0 = at(time + offset);
      for (let s = s0; s < Math.min(n, s0 + Math.round(0.12 * sr)); s++) {
        const x = (s - s0) / sr;
        f.run(noise() * 2 - 1, centre, 1.5, sr);
        const v = f.bp * Math.exp(-x / len) * Math.min(1, x / 0.001) * gain;
        sfx.L[s] += v * 0.9;
        sfx.R[s] += v;
      }
    }
  };
  // Airy whoosh that peaks on the paste.
  const whoosh = (peak, gain) => {
    const f = new SVF();
    const s0 = at(peak - 0.35);
    const s1 = at(peak + 0.45);
    for (let s = s0; s < s1; s++) {
      const time = s / sr;
      const k = time < peak ? (time - (peak - 0.35)) / 0.35 : 1 - (time - peak) / 0.45;
      f.run(noise() * 2 - 1, 700 + 2600 * Math.max(0, k), 0.9, sr);
      const v = f.bp * Math.max(0, k) ** 2 * gain;
      const [gl, gr] = panGains(-0.5 + ((time - peak + 0.35) / 0.8));
      sfx.L[s] += v * gl;
      sfx.R[s] += v * gr;
      sfxSend.L[s] += v * gl * 0.4;
      sfxSend.R[s] += v * gr * 0.4;
    }
  };

  tick(m.press, 1250, 0.2);                  // shortcut to start
  chime(m.selLand, 0.11, -0.2);              // Selected Text joins the recorder
  shutter(m.shutter, 0.5);
  chime(m.shotLand, 0.11, 0.2);              // Screenshot joins the recorder
  tick(m.typeClick, 2100, 0.12, -0.1);       // click the recorder's typing line
  // One soft keystroke per typed character, varied so it doesn't sound like a metronome.
  (tl.typing || []).forEach((key, i) => {
    const vary = Math.abs(Math.sin(i * 7.31));
    tick(key.at, key.char === " " ? 700 : 1500 + 700 * vary, key.char === " " ? 0.09 : 0.055 + 0.03 * vary, -0.25 + 0.5 * vary);
  });
  tick(m.dockClick, 2100, 0.14, 0.3);        // Dock click
  tick(m.stop, 900, 0.2);                    // shortcut to stop
  whoosh(m.pasteLand, 0.5);                  // the paste
  tick(m.sendAt, 1700, 0.12, 0.2);           // auto-send
  if (m.linkClick !== undefined) tick(m.linkClick, 2100, 0.12, 0.1);     // open the full prompt
  if (m.detailsClick !== undefined) tick(m.detailsClick, 2300, 0.09);    // expand Details
  mixInto(sfx, reverb(sfxSend, sr, { room: 0.7, damp: 0.4 }), 0.8);

  return { music, sfx };
}
