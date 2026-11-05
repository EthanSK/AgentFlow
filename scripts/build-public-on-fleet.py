#!/usr/bin/env python3
"""Build the exact published commit through The Fleet; signing stays on this Mac."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1]).resolve()
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
worker = os.environ['AGENTFLOW_FLEET_WORKER']
host = os.environ['AGENTFLOW_BUILD_HOST']
# The finite worker job uses a fresh owned directory and checks out the exact
# public source, including Git metadata required by the release provenance gate.
manifest = {'schemaVersion': 1, 'id': 'agentflow-public-release',
    'sync': {'include': ['scripts/package-public-release.sh'], 'maxTotalMiB': 1},
    'profiles': {'release': {'description': 'Build and test a source-bound public Agent Flow release', 'kind': 'build', 'timeoutMinutes': 75,
        'requires': {'tools': ['git', 'xcodebuild'], 'guiSession': True},
        'resources': ['agentflow-build'],
        'prepare': [['git', 'init'], ['git', 'remote', 'add', 'origin', 'https://github.com/EthanSK/AgentFlow.git'],
            ['git', 'fetch', '--depth', '1', 'origin', commit],
            ['git', 'checkout', '--force', 'FETCH_HEAD'],
            ['python3', '-c', 'from pathlib import Path; p=Path(".git/info/exclude"); p.write_text(p.read_text()+"\\nrelease.noindex/\\n")']],
        'env': {'AGENTFLOW_BUILD_HOST': host},
        'argv': ['bash', 'scripts/package-public-release.sh', '@SRC_DIR@/release.noindex', '--build-only'],
        'artifacts': ['release.noindex/AgentFlow-prebuilt.zip', 'release.noindex/build-receipt.json', 'release.noindex/test-summary.txt', 'release.noindex/xcode-full-tests.log'],
        'maxArtifactMiB': 128,
        'success': {'requireOutput': ['Mini build and full tests finished.']}}}}
request = {'source': str(root), 'manifest': manifest, 'profile': 'release'}
output.mkdir(parents=True, exist_ok=False)
request_path = output / 'fleet-request.json'
request_path.write_text(json.dumps(request) + '\n')
fleet = shutil.which('the-fleet') or str(Path.home() / '.local/bin/the-fleet')
if '--dry-run' in sys.argv:
    raise SystemExit(subprocess.run([fleet, 'submit', str(request_path), '--machine', worker, '--dry-run'], cwd=root).returncode)
process = subprocess.Popen([fleet, 'submit', str(request_path), '--machine', worker],
    cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
receipt_path = None
assert process.stdout is not None
for line in process.stdout:
    print(line, end='', flush=True)
    if 'fleet-runner: Receipt: ' in line:
        receipt_path = Path(line.split('fleet-runner: Receipt: ', 1)[1].strip())
if process.wait() != 0 or receipt_path is None:
    raise SystemExit('The Fleet did not return a successful release build')
receipt = json.loads(receipt_path.read_text())
if receipt['cliExitCode'] != 0:
    raise SystemExit('The Fleet release receipt did not pass')
artifacts = receipt_path.parent / 'artifacts/release.noindex'
for name in ['AgentFlow-prebuilt.zip', 'build-receipt.json', 'test-summary.txt']:
    shutil.copy2(artifacts / name, output / name)
shutil.copy2(receipt_path, output / 'fleet-receipt.json')
