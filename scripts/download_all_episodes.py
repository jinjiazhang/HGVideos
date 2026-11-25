#!/usr/bin/env python3
"""Sequential, resumable episode downloader with a free-space floor."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time
import urllib.parse
import requests

parser = argparse.ArgumentParser()
parser.add_argument('--catalog', type=Path, required=True)
parser.add_argument('--dest', type=Path, required=True)
parser.add_argument('--reserve-gib', type=float, default=30)
parser.add_argument('--limit', type=int, default=0)
args = parser.parse_args()
args.dest = args.dest.resolve()
args.dest.mkdir(parents=True, exist_ok=True)
state_dir = args.dest / '_download_state'
state_dir.mkdir(exist_ok=True)
process_lock = (state_dir / 'download.lock').open('a+')
try:
    fcntl.flock(process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('A download worker is already running for this directory')
catalog = json.loads(args.catalog.read_text(encoding='utf-8'))
origin = catalog['source']['origin']
ffmpeg = shutil.which('ffmpeg')
ffprobe = shutil.which('ffprobe')
if not ffmpeg or not ffprobe:
    raise SystemExit('ffmpeg and ffprobe are required')
session = requests.Session()
session.headers.update({'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json', 'Referer': origin + '/'})
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
reserve = int(args.reserve_gib * 1024**3)
progress_path = state_dir / 'progress.json'
index_path = state_dir / 'completed.json'
completed = json.loads(index_path.read_text()) if index_path.exists() else {}
archive_path = state_dir / 'archived.json'
archived = json.loads(archive_path.read_text()) if archive_path.exists() else {}
failure_path = state_dir / 'failures.json'
previous_failures = (json.loads(failure_path.read_text()) if failure_path.exists()
    else json.loads(progress_path.read_text()).get('failures', []) if progress_path.exists() else [])
failed = {f"{item['drama_id']}-{item['ep_num']}": item for item in previous_failures
          if f"{item['drama_id']}-{item['ep_num']}" not in completed}
started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
current = None

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, data):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temp.replace(path)

rows = [(drama, ep) for drama in sorted(catalog['dramas'], key=lambda d: int(d['id']), reverse=True)
        for ep in sorted(drama.get('episodes', []), key=lambda e: int(e['ep_num']))]

def progress(status):
    data = {'status': status, 'pid': os.getpid(), 'started_at': started_at, 'updated_at': now(),
        'destination': str(args.dest), 'total_episodes': len(rows), 'completed': len(completed),
        'failed': len(failed), 'downloaded_bytes': sum(x.get('bytes', 0) for x in completed.values()),
        'free_bytes': shutil.disk_usage(args.dest).free, 'reserve_bytes': reserve,
        'current': current, 'failures': list(failed.values())}
    save(progress_path, data)
    save(failure_path, list(failed.values()))
    print(json.dumps({k: data[k] for k in ('status', 'updated_at', 'total_episodes', 'completed', 'failed', 'downloaded_bytes', 'free_bytes', 'current')}, ensure_ascii=False), flush=True)

def available():
    # A small buffer gives the running writer time to stop before the floor.
    return shutil.disk_usage(args.dest).free > reserve + 512 * 1024**2

def edge(path, method='POST'):
    response = session.post(origin + '/api/edge/request', json={'method': method, 'path': path,
        'body': 'e30=' if method == 'POST' else '',
        'content_type': 'application/json' if method == 'POST' else ''}, timeout=(10, 25))
    response.raise_for_status()
    result = response.json()
    if result.get('status') != 1 or not isinstance(result.get('data'), dict):
        raise RuntimeError('Source did not provide playback')
    return result['data']

def playback(identifier, number, variant=0):
    endpoints = [(f'/api/videos/{identifier}/episodes/{number}/playback', 'POST')]
    for path, method in endpoints:
        try:
            data = edge(path, method)
            if 'id' in data and int(data['id']) != identifier:
                continue
            if 'ep' in data and int(data['ep']) != number:
                continue
            streams = data.get('streams') or {}
            candidates = []
            for value in (streams.get('main'), data.get('video_url'), streams.get('hevc'), data.get('video_url_hevc')):
                if isinstance(value, str) and urllib.parse.urlsplit(value).scheme == 'https':
                    if value not in candidates:
                        candidates.append(value)
            if candidates:
                return candidates[variant % len(candidates)]
        except (requests.RequestException, ValueError, RuntimeError):
            continue
    raise RuntimeError('No full playback URL available')

def inspect(path, expected):
    result = subprocess.run([ffprobe, '-v', 'error', '-show_entries', 'format=duration:stream=codec_type',
        '-of', 'json', str(path)], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Downloaded media cannot be probed')
    data = json.loads(result.stdout)
    duration = float(data.get('format', {}).get('duration', 0))
    if duration <= 0 or not any(s.get('codec_type') == 'video' for s in data.get('streams', [])):
        raise RuntimeError('Downloaded media has no video')
    if expected > 0 and duration < expected - max(3, expected * 0.03):
        raise RuntimeError('Downloaded video is shorter than episode metadata')
    return duration

def download(url, temp, log, expected_duration):
    command = [ffmpeg, '-hide_banner', '-loglevel', 'warning', '-nostdin', '-y',
        '-protocol_whitelist', 'https,http,tcp,tls,crypto', '-rw_timeout', '15000000',
        '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '5',
        '-i', url, '-map', '0:v:0', '-map', '0:a?', '-c', 'copy', '-movflags', '+faststart', str(temp)]
    with log.open('wb') as error_log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=error_log)
        last_progress = time.monotonic()
        deadline = last_progress + max(300, expected_duration * 2)
        while process.poll() is None:
            if stop.is_set() or not available():
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                return 'paused_requested' if stop.is_set() else 'paused_low_disk'
            if time.monotonic() >= deadline:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                raise RuntimeError('Episode download timed out')
            if time.monotonic() - last_progress >= 20:
                progress('downloading'); last_progress = time.monotonic()
            time.sleep(1)
    if process.returncode:
        raise RuntimeError('ffmpeg download failed; see episode log')
    return 'done'

progress('starting')
downloaded_this_run = 0
for drama, episode in rows:
    identifier, number = int(drama['id']), int(episode['ep_num'])
    key = f'{identifier}-{number}'
    folder = args.dest / f'drama-{identifier}'
    final = folder / f'episode-{number:03d}.mp4'
    current = {'drama_id': identifier, 'ep_num': number, 'relative_path': str(final.relative_to(args.dest))}
    # Verified moves are indexed separately because an active downloader owns
    # completed.json. An unmounted archive must not trigger duplicate downloads.
    if key in completed and key in archived:
        continue
    if key in completed and final.exists() and final.stat().st_size == completed[key].get('bytes'):
        continue
    if stop.is_set() or not available():
        progress('paused_requested' if stop.is_set() else 'paused_low_disk'); raise SystemExit(0)
    folder.mkdir(exist_ok=True)
    if not (folder / 'metadata.json').exists():
        metadata = dict(drama)
        metadata['episodes'] = [{k: v for k, v in ep.items() if k != 'playback'} for ep in drama.get('episodes', [])]
        save(folder / 'metadata.json', metadata)
    temp = folder / f'episode-{number:03d}.part.mp4'
    log = state_dir / f'{key}.ffmpeg.log'
    success = False
    for attempt in range(3):
        current['attempt'] = attempt + 1
        if stop.is_set() or not available():
            progress('paused_requested' if stop.is_set() else 'paused_low_disk'); raise SystemExit(0)
        try:
            expected = float(episode.get('duration') or 0)
            if not final.exists():
                url = playback(identifier, number, variant=attempt)
                progress('downloading')
                status = download(url, temp, log, expected)
                if status != 'done':
                    progress(status); raise SystemExit(0)
                duration = inspect(temp, expected)
                temp.replace(final)
            else:
                duration = inspect(final, expected)
            completed[key] = {'drama_id': identifier, 'ep_num': number, 'path': str(final.relative_to(args.dest)),
                'bytes': final.stat().st_size, 'duration_seconds': duration, 'completed_at': now()}
            save(index_path, completed)
            failed.pop(key, None)
            downloaded_this_run += 1
            success = True
            progress('episode_completed')
            break
        except Exception as error:
            if attempt == 2:
                failed[key] = {'drama_id': identifier, 'ep_num': number, 'error': str(error), 'at': now()}
            else:
                if stop.wait(2 ** (attempt + 1)):
                    progress('paused_requested'); raise SystemExit(0)
    if not success:
        progress('episode_failed')
    if args.limit and downloaded_this_run >= args.limit:
        progress('limit_reached'); raise SystemExit(0)
current = None
progress('completed' if not failed else 'completed_with_failures')
