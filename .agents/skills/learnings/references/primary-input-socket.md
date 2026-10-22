# Primary input socket qualification

Use for receiver startup failures, refused wand/mouse transport, or a native release
that changes this receiver. Keep keyboard, Primary gestures and Next routes unchanged.

- Inspect the running app's exact identity, private socket and lock-file owner/modes,
  live descriptor ownership and startup diagnostics. File existence or mode 0600 alone
  does not prove a receiver is bound.
- A passive AF_UNIX SOCK_DGRAM connect sends no message. Require connect success after
  the installed app has a persistent PID; never send down/up as a readiness probe.
  Positive ordinary input still separately controls the session-readiness gate.
- Under the existing private, nonblocking exclusive lock, production recovery accepts
  an exact recorded identity or a device-only mismatch with the same inode and owner.
  Require explicit ECONNREFUSED and recheck identity immediately before unlinking.
  Preserve live endpoints, foreign inodes/owners, regular files, symlinks and ambiguous
  failures. Do not delete a private endpoint merely because it looks old.
- For a separately authorized manual recovery, wait for idle, deliver the five-second
  warning and obtain cooperative quit before touching its endpoint. Quarantine only
  the exactly inspected stale socket and retain a marker copy. Keep the canonical
  lock inode in place; renaming it can permit two independent flock owners.
- Recheck the bound connection after relaunch and report physical button acceptance
  separately. No socket fixture, signature, connect or log alone proves real speech.

Self-improved — 2026-10-15: the recorded and live socket inode/owner matched, but
the disk device number changed. Canonical Mini fixtures cover recovery and live/foreign
rejection; a safe manual recovery restored the actual connection. See
`LEARNINGS.md`, “A socket file is not a bound Primary receiver”.
