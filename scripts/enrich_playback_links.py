#!/usr/bin/env python3
"""Add per-episode full playback URLs to a metadata export, with checkpoints."""
import argparse
import concurrent.futures
import datetime
import json
import pathlib
import shutil
import threading
import time
import urllib.parse
import requests

parser = argparse.ArgumentParser()
parser.add_argument('--file', type=pathlib.Path, required=True)
parser.add_argument('--cache', type=pathlib.Path, required=True)
args = parser.parse_args()
args.cache.mkdir(parents=True, exist_ok=True)
backup = args.file.with_name(args.file.stem + '.metadata-only.json')
if not backup.exists():
    shutil.copy2(args.file, backup)
document = json.loads(args.file.read_text(encoding='utf-8'))
origin = document['source']['origin']
local = threading.local()
rate_lock = threading.Lock()
next_request = 0.0
started = datetime.datetime.now(datetime.timezone.utc).isoformat()

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temp.replace(path)

def edge(path, method='POST'):
    global next_request
    if not hasattr(local, 'session'):
        local.session = requests.Session()
        local.session.headers.update({'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json', 'Referer': origin + '/'})
    for attempt in range(3):
        with rate_lock:
            delay = max(0, next_request - time.monotonic())
            next_request = max(time.monotonic(), next_request) + 1 / 12
        time.sleep(delay)
        try:
            response = local.session.post(origin + '/api/edge/request', json={
                'method': method, 'path': path,
                'body': 'e30=' if method == 'POST' else '',
                'content_type': 'application/json' if method == 'POST' else ''
            }, timeout=(10, 25))
            if response.status_code == 429:
                retry = response.headers.get('Retry-After', '15')
                with rate_lock:
                    next_request = max(next_request, time.monotonic() + min(int(retry) if retry.isdigit() else 15, 120))
            response.raise_for_status()
            value = response.json()
            if value.get('status') != 1 or not isinstance(value.get('data'), dict):
                raise ValueError('API business response did not contain a playback object')
            return value['data']
        except (requests.RequestException, ValueError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)

def valid_url(value):
    if not isinstance(value, str):
        return None
    parsed = urllib.parse.urlsplit(value)
    return value if parsed.scheme == 'https' and parsed.hostname else None

def parse_playback(value, identifier, episode, endpoint, method):
    if 'id' in value and int(value['id']) != identifier:
        raise ValueError('Playback drama ID mismatch')
    if 'ep' in value and int(value['ep']) != episode:
        raise ValueError('Playback episode mismatch')
    streams = value.get('streams') or {}
    main = valid_url(streams.get('main')) or valid_url(value.get('video_url'))
    hevc = valid_url(streams.get('hevc')) or valid_url(value.get('video_url_hevc'))
    preview = valid_url(streams.get('preview'))
    url = main or hevc
    if not url:
        raise ValueError('No full stream provided; preview excluded')
    explicit_expiry = next((value[k] for k in ('expires_at', 'expire_at', 'expires', 'exp') if value.get(k)), None)
    return {
        'status': 'ok', 'url': url, 'hevc_url': hevc,
        'source_field': 'main' if main else 'hevc',
        'main_matches_preview': bool(main and main == preview),
        'fetched_at': now(), 'expires_at': explicit_expiry,
        'expiry_known': explicit_expiry is not None,
        'server_timestamp': value.get('timestamp'),
        'manifest_method': value.get('manifest_method', 'GET'),
        'refresh_endpoint': endpoint, 'refresh_method': method,
        'verification': 'Full stream returned by source API; individual video not downloaded or duration-tested.'
    }

def fetch(identifier, episode, force=False):
    path = args.cache / 'links' / f'{identifier}-{episode}.json'
    if path.exists() and not force:
        cached = json.loads(path.read_text(encoding='utf-8'))
        # Checkpoints are suitable only within this export session's short window.
        age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(cached['fetched_at'])
        if cached.get('status') == 'ok' and age.total_seconds() < 3600:
            return identifier, episode, cached
    error_types = []
    endpoints = [(f'/api/videos/{identifier}/episodes/{episode}/playback', 'POST')]
    for endpoint, method in endpoints:
        try:
            result = parse_playback(edge(endpoint, method), identifier, episode, endpoint, method)
            save(path, result)
            return identifier, episode, result
        except Exception as error:
            error_types.append(type(error).__name__)
    result = {'status': 'failed', 'url': None, 'fetched_at': now(), 'errors': error_types,
              'refresh_endpoint': f'/api/videos/{identifier}/episodes/{episode}/playback', 'refresh_method': 'POST'}
    save(path, result)
    return identifier, episode, result

episodes = {(int(drama['id']), int(episode['ep_num'])): episode
            for drama in document['dramas'] for episode in drama.get('episodes', [])}
assert len(episodes) == document['counts']['episodes']
finished = 0
failures = set()

def checkpoint(done=False):
    results = [e.get('playback') for e in episodes.values()]
    success = sum(bool(p and p.get('status') == 'ok') for p in results)
    timestamps = [p['fetched_at'] for p in results if p and p.get('status') == 'ok']
    metadata = {'started_at': started, 'updated_at': now(), 'finished': done,
        'total_episodes': len(episodes), 'processed': finished,
        'succeeded': success, 'failed': len(failures),
        'earliest_fetched_at': min(timestamps) if timestamps else None,
        'latest_fetched_at': max(timestamps) if timestamps else None,
        'complete': done and success == len(episodes),
        'note': 'Signed playback URLs can expire. Null expires_at means the API did not explicitly declare expiry; server_timestamp is preserved without assuming its meaning. Only main/hevc or legacy full-stream fields are selected, never the preview field alone. The API sometimes returns the same full URL in both main and preview; this is recorded as main_matches_preview.',
        'failed_episodes': [{'drama_id': i, 'ep_num': e} for i, e in sorted(failures)]}
    document['playback_export'] = metadata
    document['schema_version'] = 2
    document['scope'] = 'All publicly listed drama and episode metadata, plus per-episode full playback links returned by source API; videos not downloaded.'
    document['completeness']['playback_links_complete'] = metadata['complete']
    save(args.file, document)
    save(args.cache / 'progress.json', metadata)
    print(json.dumps({k: metadata[k] for k in ('updated_at', 'finished', 'total_episodes', 'processed', 'succeeded', 'failed', 'complete')}), flush=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    futures = [pool.submit(fetch, i, e) for i, e in episodes]
    for future in concurrent.futures.as_completed(futures):
        identifier, number, result = future.result()
        episodes[(identifier, number)]['playback'] = result
        finished += 1
        if result['status'] != 'ok':
            failures.add((identifier, number))
        if finished % 200 == 0 or finished == len(episodes):
            checkpoint()

if failures:
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        retries = [pool.submit(fetch, i, e, True) for i, e in failures]
        for future in concurrent.futures.as_completed(retries):
            identifier, number, result = future.result()
            episodes[(identifier, number)]['playback'] = result
            if result['status'] == 'ok':
                failures.discard((identifier, number))
    checkpoint()
checkpoint(done=True)
