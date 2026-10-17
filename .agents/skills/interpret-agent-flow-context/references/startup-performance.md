# Startup reader validation and measurement

User-requested — 2026-10-08. The existing interpreter now provides a deterministic standard-library reader instead of asking each agent to invent bounded HTML extraction and then spend a second model step reading Markdown. Per-build presentation and audit history moved to historical-formats.md; universal safeguards and current styled-XML handling stay in SKILL.md. Response preferences and their required reads are unchanged.

## Reader verification

Run `python3 -m unittest discover -s <skill-dir>/tests -v`. Fifteen cases cover exact canonical payload/CRLF preservation, metadata after the real 8 KiB limit, duplicate tags/attributes, direct Markdown, local file URLs, percent encoding and entity decoding once, multi-prompt order/deduplication, unavailable files, relative/remote paths, unrelated sources and symlink escape. The CLI exposes byte/line counts, a completion marker and a labelled one-file line continuation. No HTML body or image base64 is emitted.

A representative actual multi-prompt invocation returned both requested canonical files byte-for-byte in one process. This proves payload delivery, not model understanding, visual rendering or measured end-to-end speedup. A missing end marker or a prompt-truncation notice still requires reading the missing lines; a marker alone is not a guarantee against middle truncation.

## How to measure without false attribution

Measure local logged user receipt to the first tool return that contains all initially linked canonical prompts. Match complete source bodies (apart from terminal newlines) through nested JSON tool-output encodings; do not require a speech tag because a prompt may contain only typed_text. Do not match a later unrelated prompt or a later reread after compaction. Deduplicate by exact session and turn ID. If the full canonical body is present in a batch, a different file's truncation notice does not invalidate it; partial canonical bodies do not count. Keep actual payloads and raw session logs private.

A local 50-read sample from three chats had median 11.3 seconds and mean 18.2 seconds; 38 reads came from one chat, so this is not a representative app-wide average. Median combined tool-call elapsed time was 0.49 seconds. Four conservatively isolated response-preference reads took a median 0.074 seconds of tool-call elapsed time. Receipt is not the physical Send click; a complete tool return is not proof of understanding. Scheduling, transport, context processing and reasoning cannot be separated from these timestamps. History compaction and startup steps remain other sources of delay.

The helper eliminates the metadata-to-Markdown model round trip; the old workflow typically used three tool calls including the skill read and this one uses two. Smaller instructions reduce repeated input. Do not promise a fixed number of seconds saved without subsequent comparable live turns. No background hook, automatic repair or native app restart is introduced.
