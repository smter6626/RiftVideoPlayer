# Rift 定制版交接与改造工作流

更新日期：2026-10-12。面向接手本仓库的开发者和 agent。单独阅读本文，再核对仓库源码，即可开始个性化改造。本文中的本机路径是环境说明，不应写入应用源码。

## 1. 项目身份与交接基线

本项目来自 [rafaelo96/RiftVideoPlayer](https://github.com/rafaelo96/RiftVideoPlayer)，定制仓库为 [smter6626/RiftVideoPlayer](https://github.com/smter6626/RiftVideoPlayer)，主分支为 `main`。

Rift 是 macOS 本地视频播放器，使用 SwiftUI/AppKit、AVFoundation、Metal/Core Image 和 KSPlayer。`Package.swift` 要求 Swift tools 6.0、macOS 14 或更新版本；依赖版本以 `Package.resolved` 为准。原生应用在 `Sources/Rift/`，`website/` 是独立的网站项目。

本文编写前的代码基线为 `dfec182`，关键本地提交为：

| 提交 | 改造 |
| --- | --- |
| `1fbae85` | MEMC 资源加载、单窗口启动、可移动和缩放控制栏、诊断与资源布局测试 |
| `2c8ef35` | 控制栏默认左下角最小尺寸、取消双击复位 |
| `dfec182` | 简化中文 README 的源项目引用 |

以上是交接基线，不表示未来 HEAD 永远不变。源仓库历史曾被改写，不应仅用当前共同祖先判断哪些改动属于本地定制。复核历史时优先查看上述本地提交及源码；更新上游是单独的任务。

本机环境：

- 正式应用：`/Applications/Rift.app`，本次核查版本为 `1.0.0-dev.69`。
- 最新源码：`/Users/smterpro/Workspace/RiftVideoPlayer`。
- `origin`：`git@github.com:smter6626/RiftVideoPlayer.git`；`upstream`：源仓库。
- 当前 `.build` 已清理；首次重新构建会重新解析/下载依赖并生成产物。
- 正式应用与源码目录独立。新增文档提交不会更新已安装应用，也不需要仅为文档重装应用。

## 2. 已验收的定制行为

这些行为是后续改造的回归基线。用户新需求可以明确改变它们；未涉及的行为应继续保留。

1. Finder 双击视频后只有一个正常播放窗口。主 scene 使用 `Window("Rift", id: "main")`，没有额外手工 fallback window。待打开 URL 经 `takePendingOpenURLs()` 消费，避免多份 `ContentView` 竞争或重复消费。
2. Frame+ 使用真实 Metal MEMC。资源加载通过 Bundle 语义兼容 `Rift_Rift.bundle/Contents/Resources` 与旧扁平布局；资源缺失时仍保留 crossfade fallback。
3. 控制栏四边可按比例缩放，鼠标悬停显示方向光标，缩放范围为 `0.65...1.35`，最大值还受窗口可容纳尺寸限制。
4. 顶部中央独立滑块负责移动，滑块视觉宽度为 `44pt`，交互区域为 `60pt x 8pt`，均会随控制栏整体缩放。
5. 拖动采用全局坐标和手势开始时的位置快照，拖动跟手。`controlsResizeKeepsOppositeEdgeFixed = false` 保留原有可选逻辑但关闭固定对边的缩放行为；当前仍有窗口边界约束。
6. 初始缩放为最小 `65%`，初始位置在左下角，距边缘 `8pt`。等实际尺寸测量完成才显示并开放交互。位置和缩放是 `@State`，目前不跨应用重启持久化。
7. 双击控制栏不再自动复位。拖动/缩放期间不会被自动隐藏；结束后恢复隐藏计时。字幕底部留白跟随控制栏几何变化。
8. `RIFT_FRAME_DIAGNOSTICS=1` 才启用附加诊断，默认关闭。

## 3. 关键源码入口与依赖

以下文件未特别标注时均在 `Sources/Rift/`。

| 改造意图 | 优先阅读 | 需要一起检查的联动 |
| --- | --- | --- |
| 单窗口、Finder 打开、菜单 | `RiftApp.swift`；`ContentView.handleOpenURLs`；`PlayerState.loadVideo` | 冷启动/热启动 URL 事件、队列、窗口前置、关闭后重新打开 |
| 控制栏位置、尺寸、拖动范围 | `ContentView.swift` | 尺寸测量、缩放边界、窗口尺寸改变、字幕留白、自动隐藏、鼠标命中范围 |
| 时间轴、按钮、音量、功能排布 | `PlayerControlsView.swift` | 控制栏固有尺寸、边缘命中区、移动滑块、PlayerState 状态更新 |
| 播放、速度、音轨、字幕、偏好 | `PlayerState.swift`；`PlayerTypes.swift` | 切换视频时清理、AVPlayer/KSPlayer 差异、UserDefaults |
| Frame+ 图像与节奏 | `RiftPlayerView.swift`；`FramePipeline.swift` | 源帧获取、帧对选择、MEMC/crossfade、双缓冲、统计与呈现 |
| MEMC 算法与成本 | `FramePlusMEMCEngine.swift`；`FramePlusMEMC.metal` | 纹理尺寸/格式、CPU 编码、GPU 完成、运动估计/滤波/warp |
| 资源定位或打包 | `ResourceLocator.swift`；根目录 `Package.swift` | SwiftPM Bundle 布局、安装包资源、MEMC/RIFE 加载 |
| 原生与直接 FFmpeg 播放 | `NativeVideoPlayerView.swift`；`DirectFFmpegPlayerView.swift`；`PlayerState.swift` | 后端功能可用性、HDR、同步、复杂容器 |
| RIFE 实验 | `RIFECoreMLInterpolator.swift`；`RIFEEngine.swift` | Core ML 模型、异步缓存、MEMC 路径独立性 |
| 网站 | 根目录 `website/` | 该目录的 AGENTS.md、构建和 GitHub Pages 流程 |

### 控制栏调用关系

`ControlsMoveHandle` / `ControlsResizeHandle` -> `updateControlsInteraction` -> 更新 `controlsPosition` / `controlsScale` -> `clampedControlsPosition`。

- `updateControlsSize` 测量原始尺寸；`initializeControlsPositionIfPossible` 和 `bottomLeftControlsPosition` 负责首次定位。
- 手势开始时保存 `controlsInteractionStartPosition` / `controlsInteractionStartScale`。每次位移基于开始值，避免把累计 translation 再加到不断变化的位置上。
- `finishControlsInteraction` 清理手势状态，并调用 `PlayerState.setControlsInteractionActive(false)`。
- `PlayerState.startHideTimer` 检查是否正在交互，`resetHideTimer` 续期并唤回控制栏。当前无交互约 5 秒后自动隐藏。
- `subtitleBottomPadding` 依据实际位置、缩放和可见状态计算字幕间距。

只改 UI 大小也会改变按钮/滑块的视觉大小与命中范围。只改拖动范围也可能改变字幕位置与窗口缩放行为。若需要 "视觉变小但点击范围不变"，应单独设计命中区域，不能只改 `scaleEffect`。

### 播放路径分流

`ContentView` 首先判断 `playbackBackend`：直接 FFmpeg 后端使用 `DirectFFmpegPlayerView`，否则根据 `usesNativeVideoLayer` 和 Metal 可用性选择 `RiftPlayerView` 或 `NativeVideoPlayerView`。不要假设所有格式、所有状态都经过 MEMC。

Frame+ 在当前代码对应 `.motion2Intense`。Metal 路径的插值尝试 `interpolateFrameMetal`，失败后使用 crossfade。RIFE 是另一组实验插值路径，不等同于可见的 Frame+ MEMC。`framePlusRenderFPS(for:)` 按显示器能力决定 Frame+ 目标节奏，不应仅凭 MTKView 初始化的 60 推断运行时目标。

## 4. 接手与执行顺序

### 4.1 开始前核对

在当前仓库目录执行：

```bash
git status --short --branch
git diff --stat
git diff
git remote -v
git log -5 --oneline
```

先读本文和相关源码，再查看任务涉及的差异。工作区可能有用户未提交的修改；不能通过 reset、checkout、stash 或覆盖文件消除它们。`.bak` 和 `monitor_rift.sh` 是本地遗留文件且被忽略，不应当作当前源码入口或自动删除。

### 4.2 从想要的效果到执行方案

每项个性化改造先形成可检查的简短说明：

1. 想要的效果：例如 "拖动顶部滑块时控制栏跟手，松手后位置不跳"。
2. 受影响入口：列出调用链、共享状态、布局/播放/资源依赖。
3. 风险判断：说明可能改变的联动和回归验证方法。
4. 最小执行方案：只修改实现该效果必要的代码。
5. 验收条件：分别写自动验证与人工观感要求。

然后执行已授权的修改。范围明确时可自主处理正常实现步骤；用户约束或新需求优先于本文。只读诊断任务不包含修复授权。

### 4.3 修改后验证

UI 改动应编译并人工验收；资源定位改动应跑相关测试并确认运行时加载；算法、播放后端或呈现节奏改动需要运行时数据。已有测试不覆盖真实 Finder 窗口数、拖动手感和 MEMC 画质，不能把测试通过写成这些行为已经验收。

交付说明修改文件、行为变化、验证结果和未确认的点。主观画质与操作体验由用户审核，不用 FPS 或计数代替。

## 5. 构建、测试和运行 edited 版

需要完整 Xcode 与兼容的 Swift 工具链。检查：

```bash
xcode-select -p
swift --version
```

本机当前选中 `/Applications/Xcode-beta.app/Contents/Developer`，也安装了 `Xcode.app`。临时选择工具链可使用单条命令的 `DEVELOPER_DIR`，不要默认修改整机设置。其他机器按实际 Xcode 路径选择。

在仓库根目录：

```bash
swift build
swift test
git diff --check
```

测试包括状态、文件签名、资源 Bundle 布局和 RIFE 辅助方法。`RIFEEngineBenchmarks.testRIFELatencyMatrix` 缺少 `RIFE_MODEL_URL` 时按设计跳过；不能写成 RIFE 性能已验证。传入模型后该 benchmark 会测试多个分辨率，属于额外实验。

启动 edited 版，让用户自行选择视频：

```bash
swift run Rift
```

可通过文件选择器或 CLI 传入视频路径。需要确定产物位置时：

```bash
swift build --show-bin-path
swift build -c release --show-bin-path
```

本机历史构建位于 `.build/out/Products/Debug` 和 `Release`，其他环境可能不同。根据查询结果找到 `Rift` 与 `Rift_Rift.bundle`，不要硬编码该路径。`--show-bin-path` 是位置查询，不代替实际编译。

直接运行主程序能验证播放与 UI；Finder 文件关联、冷启动 Apple Event 和包内资源必须用实际 `.app` 验证。启动前识别当前进程的完整路径，避免混淆正式版与 edited 版。

## 6. Frame+ 验收与已知问题

### 6.1 开启诊断

```bash
RIFT_FRAME_DIAGNOSTICS=1 swift run Rift
```

再选择视频，确认 Frame+ ON、Visual OFF、1x、显示器启用 ProMotion。偏好会从 UserDefaults 恢复，不能根据默认值推断测试条件。先测控制栏隐藏的稳定窗口，再单独比较可见状态。

启动日志应包含实际 `RIFT_MEMC resolvedResourcePath=...` 和 `memcEngineLoaded=true`，且不再出现 `FramePlusMEMCEngine init failed: library`。四个函数为 `memcDownsample`、`memcEstimateMotion`、`memcFilterVectors`、`memcWarp`。

典型资源为 `Rift_Rift.bundle/Contents/Resources/FramePlusMEMC.metal`；`ResourceLocator.resourceBundleRoots` 利用 `Bundle(url:)?.resourceURL`，保留扁平目录兼容候选。包内位置应实际核对，不能仅硬编码 `Contents/Resources` 来替代 Bundle 解析。

### 6.2 读懂每秒 JSON

`RIFT_DIAG` 每秒输出一个窗口；计数在窗口间清零，缺失计数键按 0 处理。使用实际 `elapsed` 计算频率，多个窗口按时长加权，避开启动、暂停和 seek。

| JSON 字段 | 含义/计算 |
| --- | --- |
| `targetFPS` / `screenMaxFPS` | 目标 FPS / 当前屏幕上限 |
| `counts.callbacks` / `drawable` / `images` | 计数除以 elapsed 得到 callback/drawable/image FPS |
| `counts.presentSubmitted` / `presented` | 提交/实际呈现计数除以 elapsed，分别报告 |
| `counts.copiedSource` | 源帧复制频率，不等于插值后输出频率 |
| `counts.memcAttempts` / `memcGenerated` / `fallback` | MEMC 尝试、成功编码、crossfade 回退 |
| `averages_ms_except_uiFPS.drawableWait` | currentDrawable 等待，单位 ms |
| `imageCPU` / `memcCPU` / `ciCPU` / `drawCPU` | 同一 averages 字典的 CPU 区间，单位 ms；draw 包含子区间与等待 |
| `gpu` / `presentInterval` | 同一 averages 字典的整个 GPU command 时长 / 呈现间隔，单位 ms |
| `counts.gpuErrors` | GPU 完成状态为 error 的次数 |

成功率 = `memcGenerated / memcAttempts`；回退率 = `fallback / memcAttempts`。尝试数为 0 时不报告成功率。`memcGenerated` 是 CPU 侧编码成功计数，还要结合 GPU 错误和呈现检查；`gpu` 是整个 command 的时长，不是单个 kernel 的时长。`uiFPS` 虽在同一字典中，单位是 FPS。

最低验收：引擎加载成功，`memcGenerated > 0`，足够插值尝试且回退显著低于 100%，没有相应 GPU 错误。目标或界面显示 120 FPS 不足以证明真实 MEMC。

### 6.3 历史测量与未解决问题

2026-09-05 资源修复后，固定 1080p30 视频、ProMotion、Frame+ ON、Visual OFF、1x、控制栏隐藏、workspace Debug 稳定窗约 15 秒，记录到：

| 指标 | 历史结果 |
| --- | --- |
| target / screen max | 120 / 120 FPS |
| render / presented | 约 119.93 FPS |
| memcGenerated / fallback | 1806 / 0 |
| present interval | 8.338 ms |
| GPU command duration | 4.309 ms |
| currentDrawable wait | 4.536 ms |
| image / MEMC encode / CI CPU | 0.362 / 0.232 / 0.199 ms |

这些是指定条件下的历史证据，不是当前版本重新实测，不能外推到 4K、HDR、其他机器、Visual ON 或其他后端。

另一次同进程、同二进制、Visual ON 测试中，控制栏可见时约 61 FPS、drawable 等待约 14 ms；隐藏时约 119 FPS、等待约 4.3 ms。具体 material、shadow 或 animation 的因果关系尚未做完单变量 A/B，`.ultraThinMaterial` 仍是候选。已验收拖动改造不等于此性能问题被修好。

后续先确认真实 MEMC，然后固定视频、窗口尺寸、Visual、速度和屏幕，逐项 A/B。GPU 超过 8.33 ms 与 GPU 较低但 drawable 长时间等待是不同瓶颈；不要同时重写 timer、vsync、drawable 数量和控制栏来猜根因。

## 7. 打包、部署和 GitHub

### 7.1 正式应用与开发产物

通常先改源码、构建 edited 版、用户验收，再按任务授权部署。交接时用户希望长期保留一个最新版正式应用和一份最新版源码；开发可以产生临时构建，结束后按任务要求清理，避免多个注册应用让 Finder 打开错版本。

要求覆盖 `/Applications/Rift.app` 时，先构建完整可审查的 `.app`，检查主程序、Info.plist、资源 Bundle、动态依赖和签名，再替换并验证 Finder 冷启动/热启动均只有一个窗口。不要只复制主程序而遗漏 MEMC 资源或依赖。

`scripts/build-release.sh` 是继承的发布脚本，包含编译、资源复制、签名、DMG 和 notarization。它假设 `.build/<configuration>/`、依赖工具/凭据，会删除已有同名产物。运行前核对真实 bin path、KSPlayer/FFmpeg 动态依赖、资源结构和工具；它不是最近稳定版已验证的一键部署保证。普通 UI 定制无需为本文申请开发者账号或执行公证。

本机正式版使用 ad-hoc 签名。版本号采用 `1.0.0-dev.<git-count>`，文档提交也会增加计数。部署后的程序版本和资源须实际核对，不能仅凭 HEAD 推断安装版已更新。

### 7.2 提交与推送

用户要求推送时，核对 diff，仅暂存本任务文件，正常提交和推送到 `origin/main` 或指定分支。源码 push 不更新本机正式应用。不要 force push 或随手推到 upstream。

```bash
git diff --check
git diff --stat
git status --short --branch
git ls-remote origin refs/heads/main
```

推送后比较本地 HEAD 与实际远端，不只依赖缓存的 origin/main。`.github/workflows/deploy.yml` 负责 website 的 GitHub Pages 发布，不自动构建或发布原生应用。

## 8. 后续方向与文档维护

以下是可选方向，不是已批准待执行任务：

- UI 个性化：配色、排布、时间轴高度、独立命中区、位置/尺寸记忆。先核对几何、自动隐藏和字幕联动。
- Frame+ 稳定性：控制栏可见性的单变量 A/B，再根据 CPU/GPU/drawable 数据优化。
- 画质：针对具体视频分析运动估计、遮挡和 warp，不把算法质量与资源加载、目标帧率混为一谈。
- 打包可复现性：实际 SwiftPM bin path、资源和动态依赖检查、独立原生构建检查。
- 格式/HDR：按 AVFoundation 与 KSPlayer 实际后端验证，不假设新上游变更已合入。

CODE_AUDIT.md 是历史审计，不是当前权威问题清单；符号、行号、警告和建议须重新核实。旧 AGENTS.md 审计已过时，本次改为指向本文。

本机原始证据在 `/Users/smterpro/Documents/deletable/9.5rift`，资源修复报告在 `13_memc_resource_fix/11_final_report.md`，窗口报告在 `14_double_window_fix/09_report.md`。固定测试视频为 `/Volumes/4TBHDD/12.24.2025.new=12/mp4/MP4_000015.mp4`。其他机器不要求存在这些路径，本文已保留关键结论与限制；引用历史数据注明条件和日期。

README 继续只写源项目引用与本地差异化改造。新功能验收后更新差异清单，并同步本文状态、入口和验证方法。自然语言以中文为主，标点优先使用键盘友好的字符，符号/API/日志保持准确。
