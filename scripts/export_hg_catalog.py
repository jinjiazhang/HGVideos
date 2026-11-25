#!/usr/bin/env python3
"""Export the native client's public catalog and episode metadata, resumably."""
import argparse
import concurrent.futures
import datetime
import json
import pathlib
import threading
import time
import requests

parser = argparse.ArgumentParser()
parser.add_argument('--origin', required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--cache', type=pathlib.Path, required=True)
args = parser.parse_args()
args.origin = args.origin.rstrip('/')
args.cache.mkdir(parents=True, exist_ok=True)
local = threading.local()
rate_lock = threading.Lock()
next_request = 0.0

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.replace(path)

def request(path):
    global next_request
    if not hasattr(local, 'session'):
        local.session = requests.Session()
        local.session.headers.update({'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json', 'Referer': args.origin + '/'})
    for attempt in range(4):
        with rate_lock:
            delay = max(0, next_request - time.monotonic())
            next_request = max(time.monotonic(), next_request) + 0.125
        time.sleep(delay)
        try:
            response = local.session.post(args.origin + '/api/edge/request', json={
                'method': 'GET', 'path': path, 'body': '', 'content_type': ''
            }, timeout=(10, 30))
            if response.status_code == 429:
                retry = response.headers.get('Retry-After', '10')
                time.sleep(min(float(retry) if retry.isdigit() else 10, 60))
            response.raise_for_status()
            value = response.json()
            if value.get('status') != 1 or not isinstance(value.get('data'), dict):
                raise ValueError('API did not return successful object')
            return value['data']
        except (requests.RequestException, ValueError):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)

def cached_request(name, path):
    target = args.cache / name
    if target.exists():
        return json.loads(target.read_text(encoding='utf-8'))
    data = request(path)
    save(target, data)
    return data

started = now()
catalog = {}
feeds = []
errors = []
for feed, suffix in [('latest', ''), ('original', '&is_original=1')]:
    first = cached_request(f'{feed}/page-1.json', '/api/videos?page=1&size=100' + suffix)
    pagination = first['pagination']
    pages = int(pagination['pages'])
    seen = set()
    def collect(data):
        for item in data.get('items', []):
            identifier = int(item['id'])
            seen.add(identifier)
            catalog.setdefault(identifier, item)
    collect(first)
    def page_request(page):
        return page, cached_request(f'{feed}/page-{page}.json', f'/api/videos?page={page}&size=100' + suffix)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for page, data in pool.map(page_request, range(2, pages + 1)):
            if int(data['pagination']['page']) != page:
                raise ValueError('Pagination mismatch')
            collect(data)
    feeds.append({'name': feed, 'reported_total': int(pagination['total']), 'fetched_unique': len(seen), 'pages': pages})
    print(json.dumps({'stage': 'catalog', **feeds[-1]}, ensure_ascii=False), flush=True)

ids = sorted(catalog, reverse=True)
save(args.cache / 'catalog.json', {'feeds': feeds, 'items': list(catalog.values())})

def detail_request(identifier):
    try:
        detail = cached_request(f'details/{identifier}.json', f'/api/videos/{identifier}')
        if int(detail.get('id', -1)) != identifier:
            raise ValueError('Detail identifier mismatch')
        return identifier, detail, None
    except Exception as error:
        return identifier, None, type(error).__name__

details = {}
finished = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    pending = {pool.submit(detail_request, identifier): identifier for identifier in ids}
    for future in concurrent.futures.as_completed(pending):
        identifier, detail, error = future.result()
        finished += 1
        if error:
            errors.append({'id': identifier, 'stage': 'detail', 'error': error})
        else:
            details[identifier] = detail
        if finished % 50 == 0 or finished == len(ids):
            progress = {'stage': 'details', 'finished': finished, 'total': len(ids), 'succeeded': len(details), 'failed': len(errors), 'updated_at': now()}
            save(args.cache / 'progress.json', progress)
            print(json.dumps(progress), flush=True)

# Retry failures after the main sweep, without dropping any catalog records.
for failure in list(errors):
    identifier, detail, error = detail_request(failure['id'])
    if not error:
        details[identifier] = detail
        errors.remove(failure)

dramas = []
for identifier in ids:
    item = dict(catalog[identifier])
    if identifier in details:
        item.update(details[identifier])
        item['_detail_status'] = 'complete'
    else:
        item['_detail_status'] = 'failed'
    # Preserve list-only values, including fields that differ from detail.
    item['_list_metadata'] = catalog[identifier]
    dramas.append(item)

catalog_complete = all(f['reported_total'] == f['fetched_unique'] for f in feeds)
result = {
    'schema_version': 1,
    'source': {'client': 'HGhubX / Guoju native iOS', 'origin': args.origin, 'feeds': feeds},
    'started_at': started, 'exported_at': now(),
    'scope': 'All publicly listed drama metadata and detail/episode metadata; no playback requests or video downloads.',
    'counts': {'dramas': len(dramas), 'details': len(details), 'episodes': sum(len(d.get('episodes') or []) for d in dramas)},
    'completeness': {'catalog_complete': catalog_complete, 'details_complete': not errors, 'errors': errors},
    'dramas': dramas,
}
save(args.output, result)
print(json.dumps({'stage': 'done', 'file': str(args.output), 'counts': result['counts'], 'completeness': result['completeness'], 'bytes': args.output.stat().st_size}), flush=True)
