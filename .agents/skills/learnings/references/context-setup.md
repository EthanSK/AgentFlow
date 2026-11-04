# New-user context setup

Use [SETUP.md](../../../../SETUP.md) as the canonical public instructions.

- During authorized setup, run `scripts/configure-screenshot-capture.sh`; `--check`
  reports the current setting without changing anything. The source first-use installer
  calls it automatically; users of the downloaded app can run it separately.
- It disables only macOS **Show Floating Thumbnail**, so the screenshot file exists before
  capture finishes. Preserve the save folder, image format and unrelated preferences.
  No extra watcher or transcription wait is needed. Clipboard-only screenshots remain
  outside file capture, and files saved after recording ends are outside that recording.
- A native screenshot may lack Spotlight/xattr metadata but have EXIF UserComment exactly
  `Screenshot`. Preserve the metadata-only fallback and the native/freshness boundaries.
- For escaped LaTeX or broken links, compare Codex's **Plain text mode**
  (`[desktop].composerPlainTextMode`) separately from Agent Flow's Mode/model settings.
  The working M5 had it on; the M1 default was off despite identical receiving-app code.
  Preserve other Codex settings. A changed file or correct clipboard is not a live pass:
  verify a fresh paste and its received message; do not rewrite old message history.
- Treat microphone choice, provider/Mode settings, screenshot saving, paste formatting,
  optional browser helpers and physical mouse mappings as separate checks. A setting
  copied from another Mac may name hardware that is absent on this one.
- Inspect a real native screenshot during recording and the final message. Do not
  claim screenshot success from a unit fixture, HUD preview or path existence alone.

User-requested — 2026-11-04: “agent flow needs to set that up for new users add to skill
and also to script if possible so its automatic”. The same request asked for resolved
issues from recent chats and the working M5 setup. Dated evidence is in LEARNINGS.md.
