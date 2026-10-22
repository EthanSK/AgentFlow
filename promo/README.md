# Agent Flow promo video

Source for the narrated video on the [Agent Flow website](https://ethansk.github.io/AgentFlow/#video).

- `narration.json` is the spoken script: voice direction plus one segment per spoken line, each
  with its start time. Everything else is timed from it.
- `timeline.mjs` turns those start times into every on-screen and sound cue. It also holds the
  two unspoken parts of the example: the typed text (`TYPED_TEXT`) and the screenshot's clock
  time (`SCREENSHOT_EPOCH`), from which the prompt viewer's timestamps are derived.
- `scene.html` is the whole picture as one 1920×1080 web page. `window.renderAt(seconds)` draws
  any moment; nothing animates on its own, so every frame is reproducible.
- `music.mjs` synthesizes the original music bed and interface sounds from code. There are no
  third-party samples or stock recordings.
- `render.mjs` renders the frames in headless Google Chrome, mixes the voice over the music,
  normalizes loudness and writes `docs/assets/agentflow-promo.mp4` (H.264 video, AAC audio),
  the captions `docs/assets/agentflow-promo.vtt` and the poster
  `docs/assets/agentflow-promo-poster.jpg`. With `--reuse-audio` it instead keeps the
  published soundtrack and captions and redraws only the picture (see below).
- `published-video.json` is written by every publishing render: the soundtrack's audio-packet
  hash, where its timing came from, and hashes of the files that drew the picture.

## narration.json

| Field | Meaning |
| --- | --- |
| `voice` | Direction for whoever generates the voice: speaker, narration and dictation delivery, accent, pace, pronunciation and file format. `render.mjs` doesn't read it. |
| `bpm` | Music tempo. One beat is `60 / bpm` seconds (0.6 s at 100 bpm). |
| `duration` | Video length in seconds. |
| `minGap` | Minimum silence, in seconds, between one segment's last sound and the next segment's start. |
| `segments` | The spoken lines, in order. |
| `segments[].id` | File name stem: the voice for a segment is `<voice folder>/<id>.wav`. |
| `segments[].kind` | `narration` for the narrator explaining; `dictation` for the narrator dictating the demo. Dictation words appear live in the recorder as she says them, drive its waveform, get a small room sound and are quoted in the captions. |
| `segments[].start` | Seconds from the start of the video where the file's first audible sound begins. Leading and trailing silence in the file is trimmed. |
| `segments[].text` | Exactly what is spoken. Captions use it word for word, and the recorder's live words are the dictation segments' text. |
| `segments[].picture` | What's on screen at that moment, for the voice director. `render.mjs` doesn't read it. |

Each segment's speech must end at least `minGap` before the next segment starts;
`node render.mjs --plan` prints every budget, and with `--voice` it checks the real files. If a
file runs long anyway, `render.mjs` delays every later segment, and the picture and sound cues tied
to them, by whole beats and says so. Change `start` values only by whole beats too: the start
times sit on the music's beat grid so the recorder, stop, paste and end card land on the music.

## Render

Needs Node.js, Google Chrome and ffmpeg.

```sh
cd promo
npm ci
node render.mjs --plan                                  # timing budgets; add --voice DIR to check files
node render.mjs --stills --out /tmp/promo-stills        # PNG stills at key moments
node render.mjs --stills --out /tmp/promo-stills 9.8 20  # stills at chosen seconds
node render.mjs --draft --out /tmp/promo-draft.mp4      # music and cues only, for checking the picture
node render.mjs --voice /path/to/voice                  # final video, captions and poster
```

The final render needs every segment's voice file, so a silent or music-only draft can't replace
the published video. `--draft` and `--stills` only write where `--out` points. Frames are kept in
a work folder (`--work DIR`, default in the system temp folder) as an encoded picture cache and reused when the timing hasn't
changed, so remixing a new voice take is quick.

### Redraw the picture over the published soundtrack

The original voice takes aren't in the repository. When only the picture changes, `--reuse-audio`
renders the current `scene.html` onto the published video's own timeline and copies its audio
packets unchanged, so the voice, music and interface sounds stay exactly as published:

```sh
cd promo
npm ci
W=/path/to/task/work          # explicit work folder: frame cache and a private copy of the source
node render.mjs --plan --reuse-audio --work "$W"                        # measured timing, no writes outside $W
node render.mjs --stills --reuse-audio --work "$W" --out "$W/stills"    # frames to inspect
node render.mjs --reuse-audio --work "$W" --out "$W/promo-preview.mp4"  # full preview, outside docs/
node render.mjs --reuse-audio --work "$W"                               # publish into docs/assets
```

- **Timing comes from the published captions**, which were written from the measured voice takes:
  each cue starts at its line's real start and ends 0.35 s after its last sound. Every caption
  must match `narration.json` word for word, and the render stops instead of guessing if a cue's
  end was clipped by the next line or the video's end. Starts that differ from `narration.json`
  are used as measured and reported, never snapped to the beat.
- The video's length and frame count come from the published MP4 (30 fps), and the new video
  must have exactly the same number of frames.
- Within a dictation line, words appear by syllable across its measured length; per-word timing
  from the original takes isn't recoverable. The recorder waveform follows the published mix
  inside the dictation lines only.
- The audio is muxed with `-c copy` in the work folder and published only if its packet hash
  (ffmpeg `streamhash`, SHA-256) equals the source's. The captions are kept byte for byte. If
  `published-video.json` records a different soundtrack, the render refuses to continue.
- Interface sounds (clicks, keystrokes, chimes, shutter, whoosh) are baked into that audio at the
  moments in `timeline.mjs`. Only move the camera or silent motion; changing a sounding moment's
  offset would put the picture out of sync with its own sounds. Before the first reuse, check
  with `git log` that the sounding moments in `timeline.mjs` and `music.mjs` are unchanged since
  the published MP4 was committed, and watch the clicks against the preview.
- A preview (`--out`) writes `<name>.mp4`, `.vtt`, `-poster.jpg` and `.receipt.json` beside it.
  Without `--out`, the video and poster in `docs/assets` are replaced, the captions are left
  as they are, and `promo/published-video.json` is updated. Needs ffmpeg/ffprobe 4.4 or later.
- `docs/index.html` already asks for the video and poster as `?v=458-plain-opening` for this
  redraw; the captions keep their query because they don't change. A later re-render needs a new
  value there, and that is a website change (Opus-authored, see `AGENTS.md`).

## Story

Talk, highlight a function, take a screenshot, then type an exact name in the recorder's
"Click to type" line during the pause after the screenshot line (no one speaks it; soft
keystrokes mark it). Codex comes forward from the Dock on the left edge (the recorder sits on
the screen's bottom edge), the stop sends one message, and its ↗ full-prompt link opens Agent
Flow's prompt viewer under "…so your agent can see what you were looking at."

## Sound

- **Music:** 100 bpm in D major. A detuned pad, a plucked arpeggio with echo, a sine sub bass,
  and a soft kick and hi-hats come in once the recorder starts, with a short lift into the paste.
  It resolves on the end card.
- **Interface sounds:** quiet clicks for the shortcut, the typing line, each keystroke, the Dock,
  stop, auto-send and the viewer's links; a soft chime when each reference joins the recorder, a
  screenshot shutter and a whoosh for the paste. They mark actions without competing with the
  voice.
- **Mix:** the music sits 6 LU below the voice between lines and ducks another 6 dB during
  speech. The renderer measures gated, K-weighted loudness, targets −16 LUFS integrated and
  applies a −2 dBFS sample-peak limiter before 48 kHz stereo AAC at 192 kbps. It then measures
  the encoded file with ffmpeg's `ebur128` filter; the reported true peak is a measurement,
  not a guaranteed ceiling from the sample limiter.

## Keep it truthful

- The voice is synthetic; `narration.json` says so for whoever generates it. The website shows
  no credit line for it: Ethan rejected one on 2026-09-27. The first line is the narrator's
  opinion, not a quote from a user.
- The narration makes only claims the website already makes. The dictation, selection and
  screenshot path are the website demo's invented example; never put real selections, paths or
  messages in the scene.
- The recorder is the website's stylized recorder (black panel, live words, Stop and Pause
  controls, mint waveform), not a pixel copy of the app. Like the native panel since build 457,
  its bottom edge sits on the screen's bottom edge. Codex appears only as a plain text label,
  with no logo.
- After the stop, Codex's message and the prompt viewer mirror `AgentFlowPromptPreview.make`
  and `AgentFlowPromptViewer.html` in v2.0.458. The opening is plain and editable: a `↗` link to
  the full prompt, every authored word, and `<selection>`/`<screenshot>` as inline code. A
  message this short then gets the canonical timeline underneath (italic tags in fixed colours,
  rainbow authored words); only a message of 5,000 UTF-16 units or more ends with the
  `Read the full prompt before answering.` link instead. The viewer has no "Your words" or
  "Full source" copy. Timing attributes in the message are drawn as `…`, as on the website.
  The Codex Mode shown has auto-send on, so the raw paste is visible for an instant before it
  renders. Both links are local files; nothing is uploaded.
- The published MP4 must be re-rendered from this scene (`--reuse-audio` keeps its soundtrack)
  before it represents v2.0.458; until then it shows the earlier rainbow opening.
- When the site's demo or those claims change, update `narration.json` and the scene to match,
  then re-render.
