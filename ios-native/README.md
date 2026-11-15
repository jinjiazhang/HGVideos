# 果剧 · 原生 iOS 客户端

独立的 SwiftUI + AVPlayer 项目，最低 iOS 17，支持 iPhone / iPad。与原有 `ios-client` 网页容器、Android APK 分开维护。

## 功能

- 剧集列表、右上角紧凑的最新 / 原创分类菜单、搜索、分页和下拉刷新。
- 原生视频控制、播放页右上角全屏入口、横竖屏播放、分集选择、自动下一集。退出全屏保留进度；如果系统暂停播放，可点击播放继续。
- 本地观看记录、退出保存进度、重新进入续播、删除记录。
- 自动发现可用线路，连接失败可重试。
- 不包含广告 SDK、网页广告、充值入口、会员或金币判断，也不提交账号凭据。

播放时按需获取接口返回的完整 `main` / `hevc` HLS 源，不缓存临时签名地址，不把 `preview` 当作完整剧集。客户端不修改服务端权益；若源站未提供完整源或停止服务，会显示不可播放提示，不能保证源站所有剧集始终可用。

## 打开与构建

直接用 Xcode 打开 `Guoju.xcodeproj`，选择 `Guoju` scheme 和模拟器运行。项目文件已生成，无需安装额外 Swift 包。

如需重新生成工程：

```sh
xcodegen generate
```

真机运行时在 Signing & Capabilities 中选择自己的开发团队。当前项目使用本机已有的开发团队，Bundle ID 为 `com.jinjiazh.guoju.native`。生成开发签名 IPA：

```sh
bash Scripts/build-ipa.sh
```

输出为上级 `output/Guoju-Native-iOS-1.0.0.ipa`。这是开发签名包，只能安装到描述文件允许的设备；签名有效期和设备数量记录在 `Research/verification.json`。已在已登记的 iPhone 上安装并成功启动；播放及全屏交互验证在模拟器完成。未发布到 App Store。

## 验证

2026-11-15，在 iPhone 16 Pro / iOS 18.6 模拟器完成：

| 项目 | 实际结果 |
| --- | --- |
| 列表、搜索、详情 | 实时接口正常返回 |
| 第 2 集原生播放 | 完整时长 221.267 秒；连续播放超过 22 秒；取得解码视频帧 |
| 拖动进度 | 跳转到 90 秒后继续播放超过 95 秒 |
| 切换第 3 集 | 完整时长 217.867 秒；连续播放超过 18 秒 |
| 退出续播 | 从已存的 93 秒继续播放到 94 秒之后 |
| 自动下一集 | 第 2 集结束后自动开始第 3 集 |
| 封面 | 实际封面解密和缩略图生成成功 |
| UI | 两列剧集列表、播放选集页及选集状态通过模拟器检查 |

6 项 XCTest 测试通过，0 失败。界面检查使用 Debug 专属的 `--ui-demo` 中性样例；上表的网络、解码、播放和续播测试均使用实时接口。Release 不支持样例启动参数。测试没有输出视频画面、导出视频或保存临时播放链接。

运行全部测试（包括两项需要联网的集成测试）：

```sh
xcodebuild -project Guoju.xcodeproj -scheme Guoju \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

离线测试可增加：

```sh
-skip-testing:GuojuTests/GuojuTests/testLiveCatalogAndSustainedNativePlayback \
-skip-testing:GuojuTests/GuojuTests/testLiveCoverResumeAndAutomaticNext
```

原始结果位于 `build/NativeTests.xcresult` 和 `build/ResumeTests.xcresult`；文本记录为 `test-native.log`、`test-resume.log`。验证范围是样本剧集与当前网络，不代表逐集观看全部内容。

## 实现与来源

| 文件 | 作用 |
| --- | --- |
| `Sources/HGService.swift` | URLSession 网络层、镜像发现、列表 / 搜索 / 详情 / 播放请求 |
| `Sources/Models.swift` | 接口数据解析、播放源选择 |
| `Sources/PlaybackModel.swift` | AVPlayer、切集、失败备用源、续播和自动下一集 |
| `Sources/Stores.swift` | 分页请求状态、本地观看记录 |
| `Sources/CoverImage.swift` | 封面解密、640 像素缩略图、内存缓存 |
| `Sources/GuojuApp.swift` | SwiftUI 页面和原生播放器容器 |

协议参考用户提供的 `HGhubX-main.zip`：`src-tauri/src/net.rs` 的 edge 请求封装、`api.rs` 的列表 / 搜索 / `api_play`、`media.rs` 的封面格式。网络请求只访问公开内容接口：

- `POST /api/edge/request` 封装逻辑请求。
- `GET /api/videos`、`GET /api/search`、`GET /api/videos/{id}`。
- `POST /api/videos/{id}/episodes/{ep}/playback`，必要时回退旧播放接口。

发布页作为数据解析，仅从固定发布页读取域名，不执行远端 JavaScript。媒体播放交给 AVFoundation，不需要 Android 原 APK 的 Flutter/AOT 修改、缓存桥接或本地代理。浏览器中的原站与 HGhubX 使用不同内容 ID，本项目直接使用 HGhubX 列表对应的 ID，避免串集。

HGhubX 原许可随包保留在 `Resources/HGhubX-LICENSE.txt`，应用“关于果剧 → 许可与版权声明”也可以查看。

Required Notice: Copyright (c) 2026 HGhubX contributors (https://github.com/zxsos/HGhubX)
