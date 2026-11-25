#!/usr/bin/env python3
"""Move a fixed snapshot of completed episodes to Personal, verifying bytes first."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--mount', type=Path, required=True)
parser.add_argument('--limit', type=int, default=0)
parser.add_argument('--refresh-manifest', action='store_true', help='Include episodes completed since the previous move')
args = parser.parse_args()
source_root = args.source.resolve()
state = source_root / '_download_state'
mount = args.mount.resolve()
target_root = mount / 'HGVideos/videos'
lock = (state / 'personal-move.lock').open('a+')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
manifest_path = state / 'personal-move-manifest.json'
archive_path = state / 'archived.json'
progress_path = state / 'personal-move-progress.json'

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    with temp.open('w', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n'); f.flush(); os.fsync(f.fileno())
    temp.replace(path)

def check_mount():
    if not os.path.ismount(mount):
        raise RuntimeError('Personal drive is not mounted; no local files will be removed')

check_mount()
target_root.mkdir(parents=True, exist_ok=True)
if args.refresh_manifest or not manifest_path.exists():
    entries = json.loads((state / 'completed.json').read_text())
    save(manifest_path, {'created_at': now(), 'source': str(source_root), 'destination': str(target_root), 'entries': entries})
manifest = json.loads(manifest_path.read_text())
if (manifest['source'], manifest['destination']) != (str(source_root), str(target_root)):
    raise SystemExit('Existing manifest belongs to a different source or destination')
entries = manifest['entries']
archived = json.loads(archive_path.read_text()) if archive_path.exists() else {}
current = None
last_report = 0.0

def report(status, error=None):
    global last_report
    moved = [v for k, v in archived.items() if k in entries]
    p = {'status': status, 'pid': os.getpid(), 'updated_at': now(), 'destination': str(target_root),
         'total': len(entries), 'completed': len(moved), 'total_bytes': sum(v['bytes'] for v in entries.values()),
         'moved_bytes': sum(v['bytes'] for v in moved), 'current': current, 'error': error,
         'local_free_bytes': shutil.disk_usage(source_root).free}
    save(progress_path, p)
    print(json.dumps(p, ensure_ascii=False), flush=True)
    last_report = time.monotonic()

def tick(stage, done):
    if stop.is_set(): raise InterruptedError('Move paused by request')
    if shutil.disk_usage(source_root).free < int(30.5 * 1024**3):
        raise OSError('Local free space near 30 GiB; move paused with source preserved')
    if current is not None:
        current['stage'] = stage; current['stage_bytes'] = done
    if time.monotonic() - last_report >= 10:
        report('moving')

def digest(path, stage):
    h = hashlib.sha256(); done = 0
    with path.open('rb') as f:
        while True:
            chunk = f.read(8 * 1024**2)
            if not chunk: break
            h.update(chunk); done += len(chunk); tick(stage, done)
    return h.hexdigest()

def copy_verified(source, destination, expected):
    check_mount()
    if source.stat().st_size != expected: raise RuntimeError('Source size differs from completed index')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.stat().st_size != expected: raise RuntimeError('Destination already exists with different size')
        source_hash = digest(source, 'hashing_source')
        if digest(destination, 'verifying_destination') != source_hash:
            raise RuntimeError('Destination content conflict; source preserved')
        return source_hash
    if shutil.disk_usage(mount).free < expected + 2 * 1024**3:
        raise RuntimeError('Not enough free space on Personal')
    partial = destination.with_name(destination.name + '.moving')
    h = hashlib.sha256(); done = 0
    with source.open('rb') as src, partial.open('wb') as out:
        while True:
            chunk = src.read(8 * 1024**2)
            if not chunk: break
            out.write(chunk); h.update(chunk); done += len(chunk); tick('copying', done)
        out.flush(); os.fsync(out.fileno())
    if done != expected or partial.stat().st_size != expected:
        raise RuntimeError('Copy size mismatch; source preserved')
    source_hash = h.hexdigest()
    if digest(partial, 'verifying_destination') != source_hash:
        raise RuntimeError('SHA256 verification failed; source preserved')
    check_mount()
    partial.rename(destination)
    return source_hash

try:
    report('starting')
    moved_this_run = 0
    for key, item in entries.items():
        source = source_root / item['path']
        destination = target_root / item['path']
        current = {'drama_id': item['drama_id'], 'ep_num': item['ep_num'], 'relative_path': item['path']}
        if key in archived and source.is_symlink():
            continue
        tick('preparing', 0)
        before = source.stat()
        source_hash = copy_verified(source, destination, item['bytes'])
        metadata = source.parent / 'metadata.json'
        if metadata.exists():
            copy_verified(metadata, destination.parent / 'metadata.json', metadata.stat().st_size)
        # Detect unexpected edits before replacing the local data with a pointer.
        after = source.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise RuntimeError('Source changed while copying; source preserved')
        check_mount()
        pointer = source.with_name(source.name + '.move-link')
        if pointer.is_symlink(): pointer.unlink()
        pointer.symlink_to(destination)
        # Record the verified copy before atomically releasing the local file.
        archived[key] = {**item, 'archive_path': str(destination), 'sha256': source_hash, 'moved_at': now()}
        save(archive_path, archived)
        pointer.replace(source)
        moved_this_run += 1
        report('file_moved')
        if args.limit and moved_this_run >= args.limit:
            report('limit_reached'); raise SystemExit(0)
    current = None
    report('completed')
except InterruptedError as error:
    report('paused_requested', str(error))
except Exception as error:
    report('paused_error', f'{type(error).__name__}: {error}')
    raise
