# Flux v1 设计规格

- 日期：2026-08-09
- 独立审查：Hermes，2026-08-10
- 状态：已批准（2026-08-10）
- 目标平台：macOS 26，Apple Silicon
- 计划公共仓库：`Zenith-Lxz/flux-macos`
- 实现分工：Codex 负责规格、验收、审查、提交与发布；Hermes 只在隔离 worktree 内实现分配的文件

## 1. 问题与目标

用户的办公流不是稳定的 Workspace，而是高频、碎片化地在 ARES、Codex、Chrome、微信、飞书、WPS、Hermes 和 Finder 之间往返。Flux 不预测用户下一步，也不要求记忆应用编号；它把最常见的意图压缩为稳定按键。

v1 的目标是让日常办公约 90% 至 95% 的界面导航不必触碰鼠标或触控板，同时保持 macOS 原生界面，不出现 Vim 式全屏字母提示层。

成功标准：

1. 高频应用可由记忆字母一次直达，并返回该应用最后活动的窗口。
2. 单击 Caps 可在当前上下文和上一上下文之间稳定往返。
3. 标准 macOS 控件可按空间方向移动焦点，只显示一个短暂、克制的焦点环。
4. 对 WPS、自绘画布、远程桌面等 Accessibility 信息稀疏的界面，提供键盘指针兜底。
5. 替代用户仍在使用的 Karabiner 映射，但不复制 Karabiner 的通用配置系统。

## 2. 设计原则

- 零常驻 UI：成功路径没有面板、列表或字母覆盖层；菜单栏只负责状态、设置和逃生。
- 不猜场景：直达、返回和方向都是确定性操作。
- 一套语法：`Caps` 表示 Flux，方向键表示空间，`Command + 字母` 表示应用地址，`Option` 表示指针兜底。
- 先原生焦点，后指针：能用 Accessibility 就移动真实焦点；不能时才移动鼠标指针。
- 失败安全：Flux 退出或事件监听失效时，键盘立即恢复系统原始行为。
- 不绑定 ARES：ARES 只是一个普通应用目标，不暴露或调用其终端、SSH、任务等内部接口。

## 3. 冻结快捷键

### 3.1 核心导航

| 按键 | 行为 | 记忆方式 |
| --- | --- | --- |
| 单击 `Caps` | Return：交换当前与上一上下文 | Caps 本身就是返回键 |
| `Caps + ←/↓/↑/→` | 向对应方向移动界面焦点 | 方向即结果 |
| `Caps + Option + ←/↓/↑/→` | 向对应方向移动指针；长按加速 | Option 是兜底层 |
| `Caps + Option + Return` | 指针主键单击 | Return 是执行 |
| `Caps + Option + Shift + Return` | 指针双击 | Shift 表示加强 |

`Caps + 方向键` 的按法固定为左手小指按 Caps、右手按方向键，解决右 Command 与方向键难以同时按的问题。

### 3.2 应用直达

应用直达统一为 `Caps + Command + 记忆字母`。Command 可由左手拇指按下，不依赖右 Command。

| 按键 | 默认目标 | 记忆词 |
| --- | --- | --- |
| `Caps + Command + A` | ARES | ARES |
| `Caps + Command + C` | Codex | Codex |
| `Caps + Command + G` | Google Chrome | Google |
| `Caps + Command + X` | 微信 | Xin |
| `Caps + Command + L` | 飞书 / Lark | Lark |
| `Caps + Command + W` | WPS | WPS |
| `Caps + Command + H` | Hermes | Hermes |
| `Caps + Command + F` | Finder | Finder |

行为合同：目标已运行时恢复它最后活动的窗口；未运行时正常启动；同一应用再次直达时不循环窗口。映射存放于本地配置，可在菜单设置中重新绑定或关闭，但 v1 不提供任意宏语言。

本机验证过的默认 bundle identifier 为：

| 目标 | Bundle identifier |
| --- | --- |
| ARES | `com.ares.terminal` |
| Codex | `com.openai.codex` |
| Google Chrome | `com.google.Chrome` |
| 微信 | `com.tencent.xinWeChat` |
| 飞书 / Lark | `com.electron.lark` |
| WPS | `com.kingsoft.wpsoffice.mac` |
| Hermes | `com.nousresearch.hermes.setup` |
| Finder | `com.apple.finder` |

### 3.3 保留的编辑映射

这些映射替代当前实际使用的 Karabiner 行为：

| 按键 | 输出 / 行为 |
| --- | --- |
| `Left Control` 作为修饰键 | `Left Command` |
| `Caps + B` | `Left Arrow` |
| `Caps + N` | `Down Arrow` |
| `Caps + P` | `Up Arrow` |
| `Caps + F` | `Right Arrow` |
| `Caps + H` | `Backspace` |
| `Caps + O` | `Return` |
| `Caps + Space` | 原生 `Control + Space`，保留输入法切换 |
| Chrome 中 `Caps + Tab` | `Option + Y` |
| 其他未占用的 `Caps + key` | 作为 `Right Control + key` 透传，保留终端中的 `Ctrl+A/C/R/L/W/Z` 等 |
| `Command + E` | `Command + M` |
| `Left Control + M` | `Return`，优先于 Left Control 的通用 Command 映射 |
| iTerm2 / ToDesk / `st` 中 `Command + C` | `Control + C`，作为可关闭的迁移兼容规则 |

未分配的 `Caps + Command + key` 不吞键，按 `Right Control + Command + key` 透传；所有未定义分支都必须有显式透传测试。

明确删除：

- 单击 Caps 输出 `/`。
- 右 Command 映射为 F19；新导航不使用右 Command。
- 面向任意键盘/任意应用的 Karabiner 规则编辑器。

`Caps + B/N/P/F` 与 `Caps + 物理方向键` 不冲突：前者是单手文本光标移动，后者是跨控件空间导航。

### 3.4 当前 Karabiner → Flux 差异清单

以下清单来自 2026-08-09 对当前选中 Karabiner profile 的只读检查，以实际 JSON 行为为准，不采信其中几处写错的 description：

| 当前规则 | Flux v1 | 决定 |
| --- | --- | --- |
| 所有键盘 `Caps Lock → Right Control` | Caps 状态机；未占用组合透传为 Right Control | 保留语义 |
| `Right Control` 单击输出 `/` | 单击 Caps 执行 Return | 按用户要求替换 |
| `Left Control → Left Command` | 同行为 | 保留 |
| 单个 Logitech 键盘 `Right Command → F19` | 无 | 删除；新设计不使用右 Command |
| Chrome `Right Control + Tab → Option + Y` | Chrome `Caps + Tab → Option + Y` | 保留；依赖现有 Chrome 扩展，真机验收 |
| `Right Control + O/H/B/N/P/F` | `Caps + O/H/B/N/P/F` | 保留 |
| 其他 `Right Control + key` | 其他 `Caps + key` 透传 Right Control | 保留 |
| `Left Control + A/V/X/Z/F/S` → 对应 Command 组合 | 通用 `Left Control → Left Command` 已覆盖 | 合并，结果不变 |
| `Left Control + M → Return` | 同行为，作为优先例外 | 保留 |
| `Command + E → Command + M` | 同行为，设置中可关闭 | 保留；验收其全局副作用 |
| iTerm2 / ToDesk / `st` 中 `Command + C → Control + C` | 同 bundle 条件兼容规则，设置中可关闭 | 过渡期保留；这些工具删除后关闭 |

本机系统输入源快捷键 60 和 61 均启用，分别对应 `Control + Space` 与 `Control + Option + Space`；因此 Flux 明确保留两者，不把它们用于点击。

## 4. 上下文模型

上下文最小结构为：

```text
bundle identifier + process identifier + focused window AX reference + timestamp
```

Flux 监听前台应用与焦点窗口变化，维护 `current` 和 `previous` 两项。单击 Caps 执行真正的交换，而不是简单打开“倒数第二个应用”，因此连续单击可稳定 A ↔ B 往返。应用退出、窗口失效或 Accessibility 拒绝时，按以下顺序降级：

1. 同 bundle identifier 的当前运行实例及其最近窗口；
2. 激活该应用的任意可用窗口；
3. 从配置路径或 Launch Services 启动应用；
4. 无可用目标时保持当前上下文，并通过菜单栏图标短暂显示失败状态。

Flux 不读取文档内容、聊天内容、终端内容或浏览历史。Chrome 当前标签、WPS 当前文档等由原应用保持；Flux 只恢复应用和窗口。

## 5. 空间焦点导航

Flux 使用 `AXUIElement` 读取当前前台窗口中可见、启用、具有有效屏幕矩形的可交互元素。候选项优先包含按钮、链接、文本框、复选框、单选框、菜单项、标签页、列表项、弹出按钮和具有 `AXPress` 等动作的元素。

方向选择采用可测试的确定性评分：

1. 排除不在目标半平面的候选项；
2. 主轴距离越近越优先；
3. 与当前元素在副轴上的重叠优先于不重叠；
4. 副轴中心偏移越小越优先；
5. 同分时按屏幕坐标和稳定遍历序号决定。

先按区域聚类再评分，避免从侧边栏直接跳到远处工具栏。导航后设置真实 Accessibility 焦点；只显示包围目标的细焦点环，约 700 毫秒后淡出。界面树变化、窗口变化或应用切换时立即失效缓存。每个应用的 AX 查询设置短超时，不能让不响应的应用卡住全局键盘。

标准控件随后使用原生 Enter 或 Space 执行。Flux 不全局劫持裸 Enter/Space，也不在输入文字时维持隐藏模式。

焦点环使用不激活的透明 `NSPanel`：不成为 key/main window、不参与窗口循环、不接收鼠标事件，并从 Accessibility 树隐藏。显示焦点环不得触发前台应用变化、污染上下文历史或成为空间导航候选项。

## 6. 键盘指针兜底

当应用没有足够的 Accessibility 元素时，`Caps + Option + 方向键` 直接移动系统指针：短按精细移动，长按逐级加速；按住 Shift 使用快速档。指针移动后尝试用 `AXUIElementCopyElementAtPosition` 对附近可交互元素吸附，但没有候选时保持纯几何移动。

`Caps + Option + Return` 和 `Caps + Option + Shift + Return` 分别执行单击、双击。这避免占用系统原有的 `Control + Option + Space` 输入源快捷键。v1 不模拟拖拽、滚轮手势、缩放手势、OCR 或图像识别；这些仍可使用原生键盘快捷键或少量触控板操作。

## 7. 原生架构

在本机只有 Command Line Tools、没有完整 Xcode 的约束下，v1 使用 Swift Package 构建原生无 Dock 图标的菜单栏应用，并由脚本组装标准 `.app`：

```text
FluxApp
├── AppDelegate / menu bar / permission onboarding
├── Input
│   ├── EventTap
│   ├── CapsGestureStateMachine
│   ├── KeyRouter
│   └── SyntheticEventMarker
├── Context
│   ├── ContextHistory
│   ├── ApplicationLauncher
│   └── WindowRestorer
├── Focus
│   ├── AXTreeReader
│   ├── SpatialNavigator
│   └── FocusRingPanel
├── Pointer
│   └── PointerController
└── Configuration
    ├── FluxConfiguration
    └── ConfigurationStore
```

核心框架：AppKit、CoreGraphics、ApplicationServices、ServiceManagement。无第三方运行时依赖。Apple 的 Accessibility API 提供 UI 元素的位置、动作、属性和通知；启动登录项使用 macOS 13 及以上的 `SMAppService.mainAppService`，只在用户显式打开开关时注册。

事件监听采用可抑制并替换按键的 `CGEventTap`。所有合成事件写入私有 `eventSourceUserData` 标记，监听器遇到该标记时直接放行，防止递归。监听被系统因超时或用户输入禁用时，先强制复位 Caps 与重复键状态，再自动尝试重新启用；失败则停用 Flux 映射并在菜单栏显示错误。

平台边界必须通过协议注入：`EventTapProviding` 管理输入事件，`AXTreeReading` 提供可交互元素快照，`FrontmostAppProviding` 提供前台应用/窗口，`EventPosting` 发送带标记的合成事件。单元测试使用替身，不依赖真实 Accessibility 权限。

### 7.1 构建与签名

- 固定 bundle identifier 为 `com.zenith.flux`，`.app` 固定组装到 `dist/Flux.app`。
- 构建脚本接受 `FLUX_CODESIGN_IDENTITY`。有稳定 Apple Development / Developer ID / 用户自备签名身份时，用该身份签名并验证 designated requirement。
- 当前钥匙串只读检查结果为 `0 valid identities found`。Flux 不自动创建自签名证书，也不修改钥匙串。
- 未提供身份时使用 ad-hoc 签名，并输出明确警告。该构建通过 SHA-256 绑定后作为本轮真机验收的唯一对象；验收期间不得重建。
- ad-hoc 二进制重建后 CDHash 可能变化，macOS 可能要求重新授予 Accessibility / 输入监控权限；README 必须写明此边界。未来若公开分发给其他用户，应使用 Developer ID 签名和 notarization，这不属于本轮已授权范围。
- `SMAppService.mainAppService` 的开机启动必须在本机单独验收；ad-hoc 签名下不预先保证可用，注册失败时设置界面显示真实错误并保持关闭，不回退为私自写入 LaunchAgent。
- `scripts/build-app.sh` 在签名后执行 `codesign --verify --deep --strict`，记录 bundle 哈希与签名方式；smoke test 只运行被记录的同一产物。

## 8. 权限、逃生与隐私

- 首次启动解释用途后请求 Accessibility 信任；如果系统还要求输入监控，提供直接打开对应设置页的说明，但不自动修改设置。
- 菜单栏提供“暂停 Flux”“打开权限设置”“开机启动”“显示快捷键”“退出”。
- `Caps + Command + Escape` 在 keyDown 时立即切换“暂停 / 运行”，作为无鼠标逃生路径；`Caps + Escape` 立即发送原生 Escape，不引入延迟。暂停态保留最小事件监听，只识别恢复和弦并放行其他全部事件，因此可以纯键盘恢复。
- Flux 不安装内核扩展、DriverKit 驱动、LaunchDaemon 或 root helper。
- Flux 不记录用户键入内容；诊断日志只允许状态、按键规则标识、bundle identifier 和错误码，默认关闭详细日志。
- Secure Input、登录窗口和系统未授权阶段不承诺拦截；这是事件监听方案的安全边界。

## 9. 配置与 UI

配置保存于 `~/Library/Application Support/Flux/config.json`，采用带版本号的稳定 schema，原子写入。默认配置开箱即用，菜单中的设置窗口只包含：

1. Flux 总开关和权限状态；
2. 八个应用直达键及应用选择；
3. 编辑映射逐项开关；
4. 指针速度；
5. 开机启动；
6. 恢复默认值。

不提供宏录制、脚本执行、网络请求、云同步、应用分类、工作区或预测功能。

## 10. 测试与验收

### 自动化门禁

- `CapsGestureStateMachine`：单击、长按、和弦、按键重复、修饰键释放顺序、快速交替、跨应用切换、Caps 按住时 tap 禁用/重启用和重启后的强制复位；断言物理 Caps keyDown/keyUp 从不转发为 Caps Lock。
- `KeyRouter`：所有冻结快捷键、优先级、Chrome 条件规则、输入源组合、未占用按键透传、合成事件不回环。
- `ContextHistory`：A→B→Return→Return、失效窗口、退出应用、Flux 自发激活不污染历史。
- `SpatialNavigator`：四方向、重叠优先、区域优先、同分确定性、空候选。
- `PointerController`：短按、长按、重复频率、分级加速、Shift 快速档和停止复位。
- `ConfigurationStore`：默认值、版本迁移、损坏文件回退、原子写入。
- `EventTapLifecycle`：超时禁用→状态复位→重启用、重启失败进入安全停用。
- `swift test`、release build、`.app` 组装和无权限启动 smoke test 全部通过。

### 本机真实验收

在临时关闭 Karabiner 映射但不卸载、不改配置的情况下，逐项验证：

1. 单击 Caps 在 Codex ↔ Chrome、Chrome ↔ 微信间各往返 10 次，无错误目标。
2. 八个应用直达键在已运行与未运行两种状态下工作；恢复最近窗口。
3. Chrome、Hermes、飞书、Finder 的标准控件可四向导航，焦点环不遮挡内容。
4. WPS 中 AX 不足时指针移动、加速、吸附、单击和双击可用。
5. 保留映射在文本编辑器、Chrome 和 ARES/终端输入中符合表格。
6. 输入法切换正常；普通 Caps 不改变大小写锁定状态。
7. 暂停、退出、崩溃模拟和事件 tap 禁用后，物理键盘保持可用。
8. 不授予权限时应用展示明确状态且不会吞键。
9. 对最终哈希绑定产物完成签名验证；若使用稳定签名身份，连续两次构建后权限保持。ad-hoc 模式只验收未重建的绑定产物，并验证 README 已说明重建需重新授权。
10. 开机启动开关按真实 `SMAppService` 状态工作；失败时显示错误、不创建替代 LaunchAgent，关闭后退出再登录不会自动启动。

只有自动化门禁和本机真实验收都通过，才能称为“可正常使用”。若某一应用因其 Accessibility 实现不足只能使用指针兜底，须在发布说明中如实列出。

## 11. 交付与提交策略

公共仓库目标为 `https://github.com/Zenith-Lxz/flux-macos`，默认分支 `main`。仓库当前不存在；创建时设为 public。建议小提交序列：

1. `docs: define Flux v1 design`
2. `build: scaffold native macOS app`
3. `feat: add deterministic Caps key routing`
4. `feat: add context return and app jumps`
5. `feat: add accessibility spatial navigation`
6. `feat: add keyboard pointer fallback`
7. `feat: add settings and safety controls`
8. `test: add integration and packaging checks`
9. `docs: add installation and permission guide`

Hermes 不提交、不推送；Codex 在每个功能边界检查 diff、运行相关测试后创建提交并推送。最终交付包含源码、release `.app`、安装/权限说明、已知限制和可复现的验证证据。

## 12. 非目标

- 不集成或控制 ARES 内部终端、SSH、任务或会话。
- 不复刻 Karabiner 的设备识别、任意 JSON 规则、虚拟 HID 和全部键盘功能。
- 不追求在登录窗口、密码框、游戏、虚拟机、远程桌面和所有自绘画布中 100% 无鼠标。
- 不加入 Vim 字母定位、全屏覆盖层、命令面板、应用列表、Workspace、AI 预测或使用行为上传。
- 不自动删除、停用或修改 Karabiner；切换由用户在验收时手动完成。
