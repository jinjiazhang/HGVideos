#!/usr/bin/env python3
"""Start, resume, inspect, or pause the sequential downloader."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('command', choices=('start', 'resume', 'status', 'pause'))
parser.add_argument('--dest', type=Path, required=True)
parser.add_argument('--catalog', type=Path)
parser.add_argument('--reserve-gib', type=float, default=30)
args = parser.parse_args()
dest = args.dest.resolve()
state = dest / '_download_state'
progress_path = state / 'progress.json'
progress = json.loads(progress_path.read_text()) if progress_path.exists() else {}
pid = progress.get('pid')
running = False
if pid:
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True,
                            text=True, errors='replace')
    running = result.returncode == 0 and 'download_all_episodes.py' in result.stdout
if args.command == 'status':
    print(json.dumps({'worker_running': running, **progress}, ensure_ascii=False, indent=2))
elif args.command == 'pause':
    if running:
        os.kill(pid, signal.SIGTERM)
        print('Pause requested.')
    else:
        print('No running worker found.')
else:
    if not args.catalog or not args.catalog.is_file():
        parser.error('start/resume requires an existing raw export passed as --catalog')
    if running:
        raise SystemExit('Download worker already running.')
    state.mkdir(parents=True, exist_ok=True)
    downloader = Path(__file__).with_name('download_all_episodes.py').resolve()
    command = [sys.executable, '-u', str(downloader), '--catalog', str(args.catalog.resolve()),
               '--dest', str(dest), '--reserve-gib', str(args.reserve_gib)]
    if caffeinate := shutil.which('caffeinate'):
        command = [caffeinate, '-i', *command]
    with (state / 'worker.log').open('ab') as log:
        worker = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log,
                                  stderr=subprocess.STDOUT, start_new_session=True)
    print(json.dumps({'pid': worker.pid, 'destination': str(dest)}))
