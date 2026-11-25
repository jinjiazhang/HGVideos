import argparse
import collections, concurrent.futures, html, json, os, shutil, stat
from pathlib import Path

parser = argparse.ArgumentParser(description='Verify archive entries and build an HTML index')
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--catalog', type=Path, action='append', required=True)
args = parser.parse_args()
source = args.source.resolve()
state = source / '_download_state'
def read(name):
    return json.loads((state / name).read_text(encoding='utf-8'))

progress = read('personal-move-progress.json')
assert progress['status'] == 'completed', progress['status']
archive_root = Path(progress['destination']).parent
assert os.path.ismount(archive_root.parent)
completed = read('completed.json')
archived = read('archived.json')
assert completed.keys() == archived.keys()
assert len(completed) == progress['completed'] == progress['total']
groups = collections.defaultdict(list)

def verify(item):
    key, entry = item
    record = archived[key]
    target = archive_root / 'videos' / entry['path']
    source_link = source / entry['path']
    assert Path(record['archive_path']) == target
    assert source_link.is_symlink() and Path(os.readlink(source_link)) == target, key
    info = target.stat()
    assert stat.S_ISREG(info.st_mode) and info.st_size == entry['bytes'] == record['bytes'], key
    assert len(record['sha256']) == 64, key
    return int(entry['drama_id']), int(entry['ep_num']), target.relative_to(archive_root).as_posix()

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
    for drama, episode, path in executor.map(verify, completed.items()):
        groups[drama].append((episode, path))
print('Verified',len(completed),'files',flush=True)

titles = {}
for path in args.catalog:
    catalog = json.loads(Path(path).read_text(encoding='utf-8'))
    titles.update({int(item['id']): item['title'] for item in catalog['dramas']})
parts = ['<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Personal 剧集索引</title><style>body{font:16px system-ui;max-width:850px;margin:32px auto;padding:0 16px}details{padding:10px;border-bottom:1px solid #ddd}summary{cursor:pointer}a{display:inline-block;margin:7px 12px 0 0}input{font:inherit;padding:8px;width:min(100%,360px)}</style><h1>Personal 剧集索引</h1>',
         f'<p>已归档 {len(groups):,} 部剧，共 {len(completed):,} 集。展开剧名，点击集数打开 MP4。</p>',
         '<input id="query" type="search" placeholder="搜索剧名或剧集 ID" aria-label="搜索剧名或剧集 ID">']
for drama, episodes in sorted(groups.items(), reverse=True):
    title = html.escape(titles.get(drama, f'剧集 {drama}'))
    links = ' '.join(f'<a href="{html.escape(path)}">第 {episode} 集</a>' for episode, path in sorted(episodes))
    parts.append(f'<details><summary>{title}（ID {drama}，已归档 {len(episodes)} 集）</summary>{links}</details>')
parts.append('<script>const q=document.getElementById("query");const rows=Array.from(document.querySelectorAll("details"));q.addEventListener("input",()=>{const needle=q.value.trim().toLowerCase();for(const row of rows)row.hidden=!row.firstElementChild.textContent.toLowerCase().includes(needle);});</script></html>')
assert sum(len(eps) for eps in groups.values()) == len(completed)

def replace_text(target, value):
    temporary = target.with_name('.' + target.name + '.pending')
    with temporary.open('w', encoding='utf-8') as file:
        file.write(value)
        file.flush()
        os.fsync(file.fileno())
    size = len(value.encode('utf-8'))
    assert temporary.stat().st_size == size
    temporary.replace(target)
    assert target.stat().st_size == size

replace_text(archive_root / '剧集索引.html', '\n'.join(parts))
replace_text(archive_root / 'README.txt', f'已下载剧集归档\n\n当前已归档 {len(groups):,} 部剧，共 {len(completed):,} 集。\n打开本目录下的「剧集索引.html」，可按剧名或剧集 ID 查找并打开视频。\n视频位于 videos/drama-剧集ID/episode-集数.mp4，各剧目录的 metadata.json 保存剧名和分集信息。\n')
print(json.dumps({'episodes':len(completed),'dramas':len(groups),'GiB':round(sum(row['bytes'] for row in completed.values())/1024**3,2),'local_free_GiB':round(shutil.disk_usage(source).free/1024**3,2)},ensure_ascii=False),flush=True)
