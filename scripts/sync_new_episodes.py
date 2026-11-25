"""Download the catalog delta and move verified files in batches to Personal."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
for flag in ('run-dir', 'catalog', 'baseline', 'previous', 'source', 'mount', 'cloud-workspace'):
    parser.add_argument('--' + flag, type=Path, required=True)
args = parser.parse_args()
scripts = Path(__file__).resolve().parent
run = args.run_dir.resolve()
run.mkdir(parents=True, exist_ok=True)
source = args.source.resolve()
state = source / '_download_state'
status_path = run / 'status.json'
lock = (run / 'job.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def read_index(name):
    path = state / name
    return read(path) if path.exists() else {}


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.replace(path)


def report(stage, **values):
    result = {'stage': stage, 'pid': os.getpid(), 'time': datetime.datetime.now().astimezone().isoformat(), **values}
    save(status_path, result)
    print(json.dumps(result, ensure_ascii=False), flush=True)


def call(script, *args):
    subprocess.run([sys.executable, '-W', 'ignore', '-u', str(script), *map(str, args)], check=True)


def indexed_episodes(catalog):
    return {(int(drama['id']), int(episode['ep_num']))
            for drama in catalog['dramas'] for episode in drama.get('episodes', [])}


def select(catalog, wanted):
    dramas = []
    for drama in catalog['dramas']:
        episodes = [episode for episode in drama.get('episodes', [])
                    if f"{drama['id']}-{episode['ep_num']}" in wanted]
        if episodes:
            dramas.append({**drama, 'episodes': episodes})
    return {'source': catalog['source'], 'counts': {'dramas': len(dramas), 'episodes': len(wanted)},
            'completeness': {}, 'dramas': dramas}


def wait_for_mount(mount, **progress):
    while not os.path.ismount(mount):
        report('waiting_for_personal', **progress)
        time.sleep(60)


def move_batch(mount, progress):
    while True:
        wait_for_mount(mount, **progress)
        report('moving', **progress)
        try:
            call(scripts / 'move_completed_to_personal.py', '--source', source, '--mount', mount, '--refresh-manifest')
        except subprocess.CalledProcessError:
            if os.path.ismount(mount):
                raise
            continue
        if read(state / 'personal-move-progress.json')['status'] != 'completed':
            raise RuntimeError('Personal move paused before the batch completed')
        return


def cloud_status(expected, workspace):
    database = workspace / 'workspace.db'
    repository = workspace / 'repository/store.db'
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
        pending = {path for path, in db.execute('select path from working_file where is_synced=0') if path in expected}
    with sqlite3.connect(repository.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
        sizes = dict(db.execute("""with recursive tree(node_id,path,size) as (
            select node_id,'/HGVideos',size from node where name='HGVideos'
            union all select n.node_id,t.path||'/'||n.name,n.size
            from node n join tree t on n.p_node_id=t.node_id
        ) select path,size from tree where path like '%.mp4'"""))
    confirmed = {path for path, size in expected.items() if sizes.get(path) == size and path not in pending}
    return len(confirmed), len(pending), len(expected) - len(confirmed) - len(pending)


def main():
    mount = args.mount.resolve()

    catalog_path = args.catalog
    deadline = time.monotonic() + 900
    while not catalog_path.is_file():
        if time.monotonic() >= deadline:
            raise RuntimeError('Catalog export did not finish within 15 minutes')
        report('checking_catalog')
        time.sleep(10)
    latest = read(catalog_path)
    old = read(args.baseline)
    previous = read(args.previous)
    if not latest['completeness']['catalog_complete'] or not latest['completeness']['details_complete']:
        raise RuntimeError('Catalog export is incomplete')
    latest_ids = indexed_episodes(latest)
    old_ids = indexed_episodes(old)
    previous_ids = indexed_episodes(previous)
    new_keys = {f'{drama}-{episode}' for drama, episode in latest_ids - old_ids}
    retired = {f'{drama}-{episode}' for drama, episode in (previous_ids - old_ids) - latest_ids}
    save(run / 'catalog-delta.json', {'new_since_last_export': len(latest_ids - previous_ids),
         'listed_since_first_export': len(new_keys), 'no_longer_listed_from_prior_delta': sorted(retired)})
    if not new_keys:
        report('completed', new_episodes=0)
        return
    delta_path = run / 'new-episode-links.json'
    if not delta_path.exists():
        save(delta_path, select(latest, new_keys))
    delta = read(delta_path)
    if not delta.get('playback_export', {}).get('finished'):
        report('fetching_links', new_episodes=len(new_keys))
        call(scripts / 'enrich_playback_links.py', '--file', delta_path, '--cache', run / 'links-cache')
        delta = read(delta_path)
    available = [f"{drama['id']}-{episode['ep_num']}"
                 for drama in delta['dramas'] for episode in drama['episodes']
                 if episode.get('playback', {}).get('status') == 'ok']
    failed = set(new_keys) - set(available)
    ready = len(available)

    batches = [available[:1]] + [available[index:index + 20] for index in range(1, ready, 20)] if ready else []
    for index, items in enumerate(batches, 1):
        batch = set(items)
        completed = read_index('completed.json')
        archived = read_index('archived.json')
        report('downloading', new_episodes=len(new_keys), links_ready=ready,
               downloaded=len(new_keys & completed.keys()), moved=len(new_keys & archived.keys()),
               failed=len(failed), batch=index)
        if batch - completed.keys():
            batch_path = run / 'current-batch.json'
            save(batch_path, select(latest, batch))
            call(scripts / 'download_all_episodes.py', '--catalog', batch_path, '--dest', source, '--reserve-gib', 30)
            completed = read(state / 'completed.json')
            download_status = read(state / 'progress.json')['status']
            if download_status.startswith('paused'):
                report(download_status, new_episodes=len(new_keys), downloaded=len(new_keys & completed.keys()),
                       moved=len(new_keys & archived.keys()))
                return
            failed.update(batch - completed.keys())
        if (batch & completed.keys()) - archived.keys():
            move_batch(mount, {'new_episodes': len(new_keys), 'links_ready': ready,
                               'downloaded': len(new_keys & completed.keys()), 'moved': len(new_keys & archived.keys())})
            if index == 1:
                call(scripts / 'verify_and_index.py', '--source', source, '--catalog', args.baseline,
                     '--catalog', args.previous, '--catalog', args.catalog)

    archived = read_index('archived.json')
    expected = {'/HGVideos/videos/' + archived[key]['path']: archived[key]['bytes']
                for key in new_keys & archived.keys()}
    failed -= archived.keys()
    assert len(expected) + len(failed) == len(new_keys)
    if expected:
        call(scripts / 'verify_and_index.py', '--source', source, '--catalog', args.baseline,
                     '--catalog', args.previous, '--catalog', args.catalog)
    workspace = args.cloud_workspace.resolve()
    save(run / 'failed-episode-ids.json', sorted(failed))
    while True:
        try:
            confirmed, pending, other = cloud_status(expected, workspace)
        except sqlite3.OperationalError:
            report('checking_cloud_again', new_episodes=len(new_keys), moved=len(expected), failed=len(failed))
            time.sleep(60)
            continue
        finished = confirmed == len(expected)
        stage = ('completed_with_failures' if failed else 'completed') if finished else 'syncing_to_cloud'
        report(stage, new_episodes=len(new_keys), links_ready=ready, moved=len(expected),
               cloud_confirmed=confirmed, cloud_pending=pending, cloud_unconfirmed=other, failed=len(failed))
        if finished:
            return
        time.sleep(60)


try:
    main()
except Exception as error:
    report('error', error_type=type(error).__name__, error=str(error))
    raise
