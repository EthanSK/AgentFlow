// Test the real Bash allowlist without starting a log stream, touching launchd,
// reading a real recording, or writing a trace/retention directory.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname, 'live-delivery-trace.sh'), 'utf8');
assert(source.includes('(process == "VoiceInkPlusPlus" || process == "AgentFlow")'),
  'trace must include the renamed production executable');
const start = source.indexOf('    case "$line" in', source.indexOf('run_trace()'));
const end = source.indexOf('    esac', start);
assert(start >= 0 && end > start, 'real trace allowlist must be found');
const redactionStart = source.indexOf('append_redacted_transcription_failure()');
const redactionEnd = source.indexOf('\nread_pid()', redactionStart);
assert(redactionStart >= 0 && redactionEnd > redactionStart);
const harness = `set -euo pipefail
append_trace_line() { printf '%s\\n' "$1"; }
${source.slice(redactionStart, redactionEnd)}
while IFS= read -r line; do
${source.slice(start, end + '    esac'.length)}
done`;
const prefix = '2026-01-01 12:00:00.000 I VoiceInkPlusPlus[123:abc] ';
const allowed = [
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] primary mouse: readiness ready=true protocolVersion=1',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] primary mouse: edge source=corsair phase=down decision=startOnDown dispatchLatencyMs=1',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] record start reservation: passive Next capture durationMs=35 requestID=synthetic targetCaptured=true',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] recorder HUD: presentation verified reason=recording start style=mini attempt=1 screens=2',
  '[com.ethansk.VoiceInkPlusPlus:FocusLock] Exact-input context scan durationMs=20 nodes=100 anchors=16 regionFiltered=true',
  '[com.prakashjoshipax.voiceink:ShortcutMonitor] Primary shortcut event received eventTimestampNs=123000000 callbackUptime=0.125',
  '[com.prakashjoshipax.voiceink:ShortcutMonitor] Typing shortcut accepted owner=recording chord=bothCommandAndOption',
  '[com.prakashjoshipax.voiceink:RecordingShortcutManager] Recording shortcut key-down action=primaryRecording dispatchLatencyMs=2',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] pipeline remove generation=2 sequence=1 recordingSessionID=synthetic',
  // Build 476 finish-stage receipts: numeric milliseconds and job lineage only.
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] prompt preparation: recipientMs=2 frontmostMs=1 appMetadataMs=0.3 hostCheckMs=0.7 scopeMs=4 candidateCount=1',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] prompt archive stages: canonicalMs=2.3 viewerMs=1.8',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] toggleRecord: stop stages stopPrepMs=0.4 micTransitionMs=0.2 hardwareStopMs=41.0 recoveryJoinMs=0.3 historySaveMs=12.5 enqueueMs=1.1 session=synthetic',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] pipeline run START queueWaitMs=180.4 generation=2 sequence=1 recordingSessionID=synthetic',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] pipeline: local stages completionPolicyWaitMs=0.1 triggerWordMs=0.2 modeResolveMs=0.3 paragraphFormatMs=4.0 wordReplacementMs=2.5 audioMetadataWaitMs=0.0 archiveMs=9.8 pasteTargetMs=0.1 leaseWaitMs=0.0 typingCommitMs=0.0 presentationMs=1.4 totalMs=18.4 generation=2 sequence=1'
].map(line => prefix + line);
const denied = [
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] primary mouse: payload=PRIVATE-COMMAND',
  '[com.ethansk.VoiceInkPlusPlus:FocusLock] Exact-input context contents=PRIVATE-CONTEXT',
  '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] record start prompt=PRIVATE-PROMPT',
  '[com.prakashjoshipax.voiceink:ShortcutMonitor] Unrelated key=PRIVATE-KEY',
  '[com.prakashjoshipax.voiceink:StreamingTranscriptionService] Final transcript=PRIVATE-TRANSCRIPT'
].map(line => prefix + line);
const failure = prefix + '[com.ethansk.VoiceInkPlusPlus:VIPPDebug] pipeline: transcribe FAILED error=PRIVATE-ERROR generation=2 sequence=1';
const result = execFileSync('/bin/bash', ['-c', harness], {
  input: [...allowed, ...denied, failure].join('\n') + '\n', encoding: 'utf8'
}).trim().split('\n');
assert.deepEqual(result.slice(0, allowed.length), allowed);
assert.equal(result.length, allowed.length + 1);
assert(result.at(-1).includes('error=<redacted> generation=2 sequence=1'));
assert(!result.join('\n').includes('PRIVATE-'));
console.log('PASS: fourteen metadata receipts retained, five content messages excluded, provider error redacted');
