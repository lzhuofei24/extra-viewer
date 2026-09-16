# Extra Viewer

> 把散落在硬盘、TF 卡和移动存储里的资料，变成一个真正可以浏览的个人资料库。

Extra Viewer 是一款 **Android 本地优先资料浏览器**。它把真实文件保持在原位置，通过目录索引、资料集和图索引组织内容；应用负责建立实体、生成预览、记录阅读与播放进度，让大量图片、视频、音频和电子书都能用同一种方式浏览。

<p align="center">
  <img src="assets/images/best_viewer_welcome.png" alt="Extra Viewer" width="720">
</p>

## 为什么是 Extra Viewer

- **资料仍归你所有**：源目录只读，应用不会改名、移动或删除原始文件。
- **一次扫描，多种组织方式**：目录索引保留原始层级，资料集用于自由整理，图索引用节点和关系表达知识结构。
- **为大资料库设计**：SQLite 写入 worker、只读查询 isolate、分页浏览和可恢复构建任务，适合从几千项扩展到十万级资料。
- **预览优先**：图片、视频、电子书和文档都会生成适合浏览的实体预览；节点可以显示合成封面和内容摘要。
- **离线可用**：不依赖云端账号，不上传文件，不把媒体复制到服务器。
- **中文友好**：支持节点名称搜索、中文短词匹配、完整路径展示和 Android SAF 目录授权。

## 核心体验

### 目录索引

选择 Android 文件目录后，Extra Viewer 会建立对应的目录树。目录节点和实体引用分开保存，文件增加、删除或更新后可以继续检查对应范围。

### 资料集

把来自不同目录的实体加入同一个资料集，建立自己的阅读专题、收藏主题或工作集合。资料集只保存引用，不复制原始文件。

### 图索引

用节点和连线组织人物、主题、项目或知识关系。图节点可以关联已有实体，搜索结果可以直接打开画布并定位到目标节点。

### 节点搜索

从资料页顶部搜索目录、资料集和图节点。搜索支持中文子串、类型筛选、完整面包屑和分页结果，不读取实体正文，也不会因为搜索加载整库缩略图。

### 内置查看器

图片、视频、音频和文档在应用内打开，并保存阅读位置和播放进度。浏览缩略图使用内存缓存，离线生成的预览资产存放在应用自己的数据目录。

## 数据原则

```text
源目录 / TF 卡 / 移动存储
          │ 只读访问
          ▼
实体 Entity ───────► 实体缩略图
          ▲
          │ 引用
目录索引 / 资料集 / 图索引
          │
          └────────► 节点预览与阅读、播放状态
```

- 原始资料只读，索引、缩略图、数据库和缓存写入应用私有目录。
- Android 使用系统文件选择器和持久化 SAF 授权访问目录。
- 快速文件指纹使用首 8 KB 加文件大小的 SHA-256；它用于判断扫描结果，不代替完整内容校验。
- 取消或放弃构建不会删除已经提交的资料；失败项可以单独重试。
- 诊断页可以查看构建阶段、失败项和数据库 schema，便于定位大容量 TF 卡上的问题。

## 获取与安装

当前发布目标为 Android arm64 平板。

### 直接安装 APK

从仓库的 [Releases](https://github.com/lzhuofei24/extra-viewer/releases) 下载 `extra-viewer-1.0.0-arm64.apk`，在 Android 平板上允许安装未知来源应用后安装。

### 从源码构建

需要 Flutter、Android SDK、Android NDK、JDK 21 和已配置的 Android license。Windows 电脑可作为 Android 构建主机使用。

```powershell
flutter pub get
flutter analyze
flutter test
.\tools\build-android-release.ps1
```

构建脚本会生成：

```text
dist/extra-viewer-1.0.0-arm64.apk
dist/extra-viewer-1.0.0.aab
dist/SHA256SUMS.txt
```

Release 包使用正式签名配置。签名文件位于本机用户目录，不会进入仓库；没有签名配置时构建会直接失败。

## 项目结构

```text
lib/src/      Flutter 应用与领域模块
android/      Android 原生 SAF、预览和播放器桥接
assets/       应用内静态资源
docs/         架构、术语和开发文档
tools/        构建与维护脚本
```

主要模块位于 `lib/src/`：

- `core/database`：SQLite schema、读写 worker 和领域仓储
- `core/controllers`：索引构建、缩略图和任务恢复
- `modules/library`：资料、节点和搜索接口
- `modules/build`：可暂停、可恢复的构建任务
- `modules/previews`：实体和节点预览资产
- `modules/viewer`：媒体查看器、阅读位置和播放状态
- `ui`：浏览、索引管理、图画布、诊断和设置页面

## 开发状态

Extra Viewer 目前处于 Android 内测阶段。项目重点是本地资料管理、长任务恢复和大规模媒体浏览；搜索只覆盖节点名称，不索引实体名称、文件正文或云端内容。

欢迎通过 [Issues](https://github.com/lzhuofei24/extra-viewer/issues) 提交崩溃日志、性能数据和功能建议。提交问题时请附上 Android 版本、设备型号、资料来源类型，以及诊断页中与问题相关的摘要。

## 许可证

许可证和第三方依赖说明将在正式公开发布前补充。
