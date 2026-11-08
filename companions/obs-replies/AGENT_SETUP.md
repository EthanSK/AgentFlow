# Set up OBS spoken replies

Read README.md first. This workflow is optional and requires the user's explicit
request to listen after spoken reminders. Never enable it while merely fixing
Agent Flow dictation or setting up the ordinary app.

1. Preserve active recording/calls. Do not restart Agent Flow or OBS, change the
   mic/provider/Mode, enable permissions, or alter mixer tracks to make setup pass.
   Read the existing shared speech scripts before preparing their exact patch.
2. Read the installed Agent Flow effective enabled Mode (active, otherwise enabled
   default) and existing credential privately. The adapter currently supports only
   `gpt-live-transcribe`; no alternate model is selected. Never dump preferences,
   credentials, OBS settings, transcripts or environment variables.
3. Query OBS live via its existing loopback WebSocket. Its saved global.ini can be
   stale. Identify the actual `adv_file_output` path, unpaused status, microphone
   source/device/routing and separate system-output track. Verify MKV stream titles
   with FFprobe. Do not assume a microphone or stream index from this example.
4. Create a feature-owned Python environment and install `requirements.txt` there,
   preserving global packages. Put final installed files in Application Support;
   follow the host's scratch policy for sizeable temporary builds/downloads.
5. Prepare a private JSON file with these fields, using verified local values:

   ```json
   {
     "enabled": true,
     "runtime_directory": "/Users/YOU/Library/Application Support/AgentFlow/OBS Replies/runtime",
     "state_directory": "/Users/YOU/Library/Application Support/AgentFlow/OBS Replies/state",
     "python": "/Users/YOU/Library/Application Support/AgentFlow/OBS Replies/venv/bin/python3",
     "ffmpeg": "/opt/homebrew/bin/ffmpeg",
     "ffprobe": "/opt/homebrew/bin/ffprobe",
     "agent_bridge": "/Users/YOU/.local/bin/agent-bridge",
     "obs_config": "/Users/YOU/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json",
     "speech_scripts": "/Users/YOU/.codex/skills/speak-action-reminder/scripts",
     "working_directory": "/Users/YOU/Projects/AgentFlow",
     "input_name": "YOUR_VERIFIED_MIC_SOURCE",
     "input_device_uid": "YOUR_VERIFIED_MIC_DEVICE_UID",
     "track_title": "YOUR_VERIFIED_MIC_TRACK_TITLE",
     "system_track_title": "YOUR_VERIFIED_OUTPUT_TRACK_TITLE"
   }
   ```

6. Run `python3 obs_replies.py doctor --settings /absolute/private/settings.json`.
   A preflight is not an accepted live reply. The microphone may be nominally
   shared with silent camera/browser sources; actual meter coverage must prove
   those sources emitted no audio during the reply window.
7. Run `python3 install.py --settings /absolute/private/settings.json` to prepare
   the dry-run. Inspect the exact integrated source and run the focused checks,
   including existing speech/notification invariants, before `--apply`. The
   installer preserves rollback copies, performs atomic source replacement and
   publishes the enabled config last. Native app/signing/settings remain untouched.
   A previously integrated hook is deliberately refused: compare its recorded
   backup and installed sources before an explicit migration. A marker alone
   must never make the installer retain an older hook while claiming an update.
8. Add the companion's interpretation contract to the existing recovery/speech
   and question skills; do not introduce another overlapping skill. Use the
   helper below to consume one offered question result once:

   ```sh
   python3 consume-question.py --thread-id EXACT_UUID --question-id EXACT_ID
   ```

   An agent may read the offered raw transcript and judge an obvious reply; this
   helper never answers a question card, grants approval, sends a chat message or
   changes the question's status. Ambiguous or unrelated audio is not adopted.
9. Verify a real reminder end timestamp, the receipt's `anchorKind` (a
   `live-mic-meter` result means OBS's system capture delivered no audio), full15-second mic
   extraction, current-model result and exact question/chat identity. Test silence,
   echo, interruption, new input and duplicate-dispatch rejection. Keep fake tests,
   real provider probes, installation and user acceptance distinct.
10. For completed-message replies, verify the current Agent Bridge ownership delay,
    Desktop visibility and hook behavior. Do not claim instant conversation or
    disable its ownership guard without the user's informed direction. A message
    can be queued successfully while its actual agent turn remains pending.

Keep microphone PCM out of durable logs and system audio off the provider. The
tiny private receipts identify the event, original spoken text, timing, result
and routing; transcripts are machine observations, not verbatim guarantees.
