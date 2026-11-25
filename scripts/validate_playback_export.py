#!/usr/bin/env python3
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import pathlib
import random
import urllib.parse
import requests

parser = argparse.ArgumentParser(description='Validate a local playback-link export')
parser.add_argument('--file', type=pathlib.Path, required=True)
path = parser.parse_args().file
doc = json.loads(path.read_text(encoding='utf-8'))
assert doc['playback_export']['finished'], 'Export must finish before validation'
backup = json.loads(path.with_name(path.stem + '.metadata-only.json').read_text(encoding='utf-8'))
original = {int(row['id']): row for row in backup['dramas']}
rows = []
failures = []
for drama in doc['dramas']:
    stripped = json.loads(json.dumps(drama))
    for episode in stripped.get('episodes', []):
        episode.pop('playback', None)
    assert stripped == original[int(drama['id'])], 'Original drama metadata changed'
    for episode in drama.get('episodes', []):
        playback = episode['playback']
        if playback['status'] == 'ok':
            assert urllib.parse.urlsplit(playback['url']).scheme == 'https'
            assert playback['source_field'] in ('main', 'hevc')
            assert playback['fetched_at']
            rows.append((int(drama['id']), int(episode['ep_num']), episode))
        else:
            failures.append((int(drama['id']), int(episode['ep_num']), episode))

ordered = sorted(rows, key=lambda row: row[2]['playback']['fetched_at'])
samples = random.Random(0).sample(ordered, min(10, len(ordered)))

def check(row):
    identifier, episode, value = row
    url = value['playback']['url']
    result = {'drama_id': identifier, 'ep_num': episode, 'declared_duration': value.get('duration'),
              'fetched_at': value['playback']['fetched_at']}
    try:
        if not urllib.parse.urlsplit(url).path.lower().endswith('.m3u8'):
            result['status'] = 'not_hls_manifest'; return result
        with requests.get(url, timeout=(10, 25), stream=True) as response:
            result['http_status'] = response.status_code
            response.raise_for_status()
            data = bytearray()
            for chunk in response.iter_content(16384):
                data.extend(chunk)
                if len(data) > 2_000_000:
                    raise ValueError('Manifest unexpectedly large')
        text = data.decode('utf-8-sig')
        assert text.startswith('#EXTM3U')
        lengths = [float(line.split(':', 1)[1].split(',')[0]) for line in text.splitlines() if line.startswith('#EXTINF:')]
        result.update({'status': 'ok', 'segments': len(lengths), 'manifest_duration': round(sum(lengths), 3),
                       'has_endlist': '#EXT-X-ENDLIST' in text})
        declared = float(value.get('duration') or 0)
        result['duration_matches_metadata'] = bool(lengths and declared > 0 and abs(sum(lengths) - declared) <= max(2, declared * 0.02))
    except Exception as error:
        result['status'] = 'failed'; result['error'] = type(error).__name__
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    checks = list(pool.map(check, samples))

for identifier, number, episode in failures:
    try:
        response = requests.post(doc['source']['origin'] + '/api/edge/request', json={
            'method': 'POST', 'path': f'/api/videos/{identifier}/episodes/{number}/playback',
            'body': 'e30=', 'content_type': 'application/json'
        }, headers={'User-Agent': 'Mozilla/5.0', 'Referer': doc['source']['origin'] + '/'}, timeout=25)
        value = response.json()
        episode['playback']['source_status'] = value.get('status')
        episode['playback']['source_message'] = value.get('msg')
    except Exception:
        pass

assert len(rows) + len(failures) == doc['counts']['episodes']
assert len(rows) == doc['playback_export']['succeeded']
assert len(failures) == doc['playback_export']['failed']
doc['playback_validation'] = {
    'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'original_metadata_unchanged': True, 'all_episodes_have_playback_result': True,
    'successful_links_use_https': True, 'success_count': len(rows), 'failure_count': len(failures),
    'manifest_samples': checks,
    'note': 'Only these sample HLS manifests were fetched for checks; video segments were not downloaded. API link retrieval is not a playback test of every episode.'
}
temp = path.with_suffix('.json.tmp')
temp.write_text(json.dumps(doc, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
temp.replace(path)
print(json.dumps({'file': str(path.resolve()), 'successes': len(rows), 'failures': len(failures),
                  'bytes': path.stat().st_size, 'samples': checks,
                  'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}, ensure_ascii=False, indent=2))
