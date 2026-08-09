# Flux

Flux 是一个原生 macOS 键盘导航工具：用一套稳定、低记忆成本的快捷键完成上下文返回、应用直达、界面控件导航和少量指针兜底。正常工作时没有覆盖层，也不会在屏幕上铺字母；除主动打开设置外，交互都留在你正在使用的应用里。

当前版本已经实现核心输入、上下文恢复、空间焦点、指针兜底、本地配置和原生设置窗口。最低系统版本是 macOS 13；当前构建与烟雾测试脚本验证的是 Apple silicon `arm64` 产物。

## 快捷键

| 快捷键 | 行为 |
| --- | --- |
| 单击 `Caps` | 返回上一个位置（应用 + 已记住的窗口） |
| `Caps + 方向键` | 移动到对应方向的可交互控件 |
| `Caps + Option + 方向键` | 移动指针；长按逐档加速，按住 `Shift` 直接快速移动 |
| `Caps + Option + Return` | 单击 |
| `Caps + Option + Shift + Return` | 双击 |
| `Caps + Command + A/C/G/X/L/W/H/F` | 直达 ARES / Codex / Chrome / 微信 / 飞书 / WPS / Hermes / Finder |
| `Caps + Command + Escape` | 暂停或恢复 Flux |
| `Caps + B/N/P/F` | 文本光标左 / 下 / 上 / 右 |
| `Caps + H/O` | 退格 / 回车 |
| `Caps + Space` | 原生输入法切换 |
| 其他 `Caps + key` | 作为 `Right Control + key` 透传 |
| `Left Control` | 作为 `Left Command` |
| `Left Control + M` | 回车 |
| `Command + E` | `Command + M` |

Chrome 中 `Caps + Tab` 默认发送 `Option + Y`。iTerm2、ToDesk 和 `st` 中的纯 `Command + C` 默认兼容为 `Control + C`；它是迁移规则，可以在设置中关闭。应用绑定和编辑映射都能在菜单栏的“设置…”中调整。

## 本地构建

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/smoke-test.sh
```

产物位于 `dist/Flux.app`。`build-app.sh` 默认使用 ad-hoc 签名；如果你已有有效签名身份，可以显式提供：

```bash
FLUX_CODESIGN_IDENTITY="Apple Development: Your Name (...)" ./scripts/build-app.sh
```

脚本不会创建证书、修改钥匙串、授予系统权限或注册开机启动。

## 安装与首次启动

1. 完成构建和 smoke test。
2. 将同一个已验证产物复制到固定位置，例如：

   ```bash
   ditto --noextattr --noqtn dist/Flux.app /Applications/Flux.app
   open /Applications/Flux.app
   ```

3. 在 Flux 菜单中选择“打开权限设置”，为固定安装路径下的 Flux 授予：
   - 系统设置 → 隐私与安全性 → 辅助功能；
   - 系统设置 → 隐私与安全性 → 输入监控。
4. 如果授权后状态没有刷新，完全退出再打开 Flux。

Flux 是菜单栏应用，不显示 Dock 图标。正常状态显示键盘图标；黄色警告表示权限未齐；带斜线的闪电表示监听启动失败；暂停时显示暂停图标。

### ad-hoc 签名边界

ad-hoc 重建会改变二进制身份，macOS 可能要求重新授予辅助功能或输入监控权限。因此真机验收应始终使用 `dist/build-info.txt` 和 `dist/Flux.app.sha256` 绑定的同一份产物，验收期间不要重建。面向其他用户公开分发仍需要 Developer ID 签名与 notarization；当前仓库没有把本机构建描述成已公证发行版。

## 从 Karabiner 安全迁移

Flux 与 Karabiner 同时改写 Caps 时会竞争同一批物理事件。不要让两套重叠规则长期同时启用。

推荐顺序：

1. 保留 Karabiner 配置作为可恢复备份。
2. 退出 Flux，先在 Karabiner 中关闭与 Caps、Left Control、`Command + E` 和旧终端复制相关的规则，或暂时退出 Karabiner。
3. 启动固定路径下的 Flux，确认菜单栏状态为运行中。
4. 逐项验证下方验收清单；确认无误后再决定是否卸载 Karabiner。

如果需要回退，按 `Caps + Command + Escape` 暂停 Flux（或从菜单退出），然后重新启用原 Karabiner 规则。Flux 不会自动修改或删除 Karabiner 配置。

## 设置与本地数据

配置保存在：

```text
~/Library/Application Support/Flux/config.json
```

配置采用版本化 JSON、同目录原子替换，目录和文件分别收紧到不宽于 `0700` / `0600`。读取缺失、损坏或未来版本配置时 Flux 使用内置默认值，但读取过程不会覆盖原文件。设置仅包含：总开关、权限状态、8 个应用绑定、编辑映射、指针速度、开机启动和恢复默认值。

Flux 不提供宏录制、脚本执行、网络请求、云同步、应用分类、工作区预测或键入内容日志。详细设计见 [`docs/superpowers/specs/2026-08-09-flux-design.md`](docs/superpowers/specs/2026-08-09-flux-design.md)。

## 真机验收清单

- 单击 Caps 在 Codex ↔ Chrome、Chrome ↔ 微信间各往返 10 次，窗口目标正确。
- 8 个 `Caps + Command` 应用直达键逐项验证“已运行恢复 / 未运行启动”。
- 在原生设置、Chrome、飞书、WPS 和 Codex 中验证四向空间焦点；没有目标时不乱跳。
- 验证指针四向移动、长按加速、Shift 快速、单击和双击。
- 验证文本导航、输入法、Left Control、`Command + E` 与可关闭的旧终端复制规则。
- 暂停 Flux 后普通键盘完全透传，并能用同一逃生和弦恢复。
- 拔插键盘、睡眠唤醒、锁屏返回后不出现 Caps 卡住或重复触发。
- 在设置中修改一个应用绑定、关闭一项映射、调整速度，重启后仍保持。
- 显式切换开机启动并在重新登录后验证；失败时 Flux 不会私自创建 LaunchAgent。

Secure Input、登录窗口和系统尚未授权阶段不承诺拦截，这是用户态事件监听方案的边界。
