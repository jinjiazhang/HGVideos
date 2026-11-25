# HGVideos

「果剧」原生 iOS 客户端，使用 SwiftUI 和 AVPlayer，支持 iOS 17 及以上版本。

源码和 Xcode 工程位于 [`ios-native`](ios-native/README.md)。直接打开 `ios-native/Guoju.xcodeproj` 即可构建运行。

主要功能包括剧集列表、搜索、分集播放、全屏播放、自动下一集和本地续播。接口与封面处理参考 HGhubX；相关许可及版权声明保留在客户端目录中。

仓库不包含 APK、IPA、签名证书、构建缓存或抓取数据。真机安装需要配置自己的 Apple 开发签名。

## 剧集数据与归档工具

- [剧集目录快照](data/catalog.json)包含剧名、简介和分集信息。
- [归档工具说明](scripts/README.md)涵盖目录导出、下载续跑、迁移和同步确认。
