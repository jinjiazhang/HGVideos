# 剧集归档工具

适用于 macOS / Linux。需要 Python 3.9+。下载视频还需要 PATH 中的 `ffmpeg` 和 `ffprobe`。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements.txt
```

[data/catalog.json](../data/catalog.json) 是 2026 年 11 月 22 日成功导出的目录快照，包含 1,848 部剧、9,449 集的公开元数据。各脚本的操作清单由导出命令生成，包含数据源配置。Git 快照用于查阅元数据。

## 导出、校验和下载

将 `SOURCE_ORIGIN` 设为有权访问、且当前支持目录和播放接口的 HTTPS 数据源。历史数据源在 2026 年 11 月 25 日返回「接口已停用」，目录快照不会随源站自动更新。

```sh
.venv/bin/python scripts/export_hg_catalog.py --origin "$SOURCE_ORIGIN" \
  --output output/catalog.json --cache output/catalog-cache
.venv/bin/python scripts/enrich_playback_links.py --file output/catalog.json \
  --cache output/playback-cache
.venv/bin/python scripts/validate_playback_export.py --file output/catalog.json
.venv/bin/python scripts/video_download_control.py start \
  --catalog output/catalog.json --dest output/videos
.venv/bin/python scripts/video_download_control.py status --dest output/videos
```

链接导出会创建一份 `*.metadata-only.json` 备份。下载器开始一集时向数据源申请有效播放地址。下载默认保留约 30 GiB 可用空间，任务日志和断点记录写入目标目录的 `_download_state`。可用 `pause` 暂停，用 `resume` 继续。建议将原始导出、链接、日志、缓存和视频保存在已忽略的 `output/` 下。

## 迁移到 Personal 与重新生成索引

将 `PERSONAL_MOUNT` 设为实际挂载点。迁移工具逐个校验目标文件，然后用指向归档文件的符号链接替换本地原文件。目标路径为 `HGVideos/videos`。

```sh
.venv/bin/python scripts/move_completed_to_personal.py --source output/videos \
  --mount "$PERSONAL_MOUNT" --refresh-manifest
.venv/bin/python scripts/verify_and_index.py --source output/videos \
  --catalog data/catalog.json
```

## 增量下载和同步确认

`sync_new_episodes.py` 接收最新原始目录 `--catalog`、基线目录 `--baseline` 和上一轮目录 `--previous`。使用新的 `--run-dir` 存放本轮状态。传入 `--source`（本地视频目录）、`--mount`（Personal 挂载点）和 `--cloud-workspace`（该云盘的本地工作区）。

脚本按基线差集分批下载和迁移。云端确认依赖当前云磁盘客户端的 SQLite 表结构，使用只读连接比对同步队列与客户端记录的远端文件大小。其他云盘可分别使用下载、迁移及索引命令。
