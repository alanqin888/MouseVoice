# MouseVoice — 原生 macOS 长按语音测试工具

这是验证 当前输入法或语音软件能否接受**软件生成 Fn** 的最小实验，不是语音识别软件。原生 Swift + AppKit/CoreGraphics；无网络请求、无第三方依赖、不录音、不自动开机启动。首次运行默认暂停；手动启用后，下次打开会恢复上次的启用状态。

## 直接运行

1. 推荐解压 **MouseVoice.app.zip**，把里面的 **MouseVoice.app** 移到“应用程序”文件夹，再双击打开。菜单栏出现黑白鼠标/声波图标，没有主窗口或 Dock 图标。请将解压的应用放在“应用程序”文件夹运行。
2. 点击菜单栏图标，按需要使用“申请输入监控权限”和“申请辅助功能权限”。在 **系统设置 → 隐私与安全性 → 输入监控 / 辅助功能** 中允许 **MouseVoice**。如果系统未列出它，使用 `+` 手动添加你实际运行的 app。
3. 如果系统要求退出重开，照做。授权后点击 **启用**，菜单显示“已开启”；之后打开应用会恢复上次的开关状态。若上次手动暂停，重新打开仍保持暂停。
4. 确保 当前语音软件 已运行，并且**真实键盘长按 Fn、松开 Fn** 能正常开始和结束语音。把光标放到可输入文字的位置，实际按住鼠标左键约 0.5 秒；或**物理按下触控板并保持**，不要只轻点。
5. 保持基本不动，触发后开始语音；松开结束。通过 当前语音软件 的录音界面、声音提示或实际转写判断结果。

工具本身不需要麦克风、屏幕录制或自动化权限。当前语音软件 自己的录音权限由 当前语音软件 管理。监听权限与发送权限分开检查；本机不同版本的 macOS 可能允许已获辅助功能权限的进程直接监听，菜单会显示实际检测值。

## 交互规则

- 原地保持默认 **0.5 秒**后发送 Fn down；松开时发送 Fn up。
- 距离起点超过 **6 个 Quartz 屏幕坐标点**取消本次手势（不是 Retina 物理像素）。移回原位不会重新触发。
- 触发后继续拖动，同样立即发送释放事件。
- 不区分外接鼠标和触控板产生的左键事件。轻点来点按、轻点拖移、拖移锁定等是否等同持续按下由系统设置决定；这个版本不读取设备原始触摸数据。
- 使用被动监听，不拦截或修改鼠标点击。原程序仍会收到长按，可能出现文本选择、按钮长按等原有行为；原输入焦点也可能受点击影响。
- 等待期间仅使用一次性计时器；触发后每 0.2 秒检查漏掉的松开，并在默认 60 秒时释放。正常鼠标松开会立即释放。
- 暂停、切换配置、打开自身菜单、监听被禁用、休眠、会话切换、正常退出及 SIGTERM/SIGINT 均安排取消/释放。锁屏还监听系统通知。强制杀进程、崩溃或权限突然撤销不能保证释放送达；必要时实际按下并松开 Fn，检查 当前语音软件 状态。
- Fn/Command/Option/Control/Shift 已被物理按住时不会开始合成手势。测试过程中也请避免同时操作其他快捷键。

## Fn 实验到底能证明什么

实现发送虚拟键码 `63`（SDK 的 `kVK_Function`），事件类型为 `flagsChanged`；按下设置 `maskSecondaryFn`，释放清除此位，再通过 `CGEvent.post` 投递。

**已发出事件不等于 当前语音软件 接受了事件。** Apple 公开了 Fn 状态位和事件生成 API，但没有保证软件事件等同物理 Globe/Fn 键。当前语音软件 如果读取更底层设备输入、过滤合成事件，或使用了与普通快捷键不同的系统机制，可能不会响应。当前没有对 当前语音软件 内部实现作出判断。

菜单中的“合成 Fn 回读”记录带有本工具标记、再次经过监听器的 Fn 事件。它证明事件经过了监听位置，不能证明 当前语音软件 进入录音或结束录音。外部 Fn 也会记录为“外部 Fn”，不据此声称一定来自物理键盘。

建议按顺序比较：

| 测试 | 预期 / 结论 |
|---|---|
| 真实 Fn 按住后松开 | 先确认 当前语音软件 本身正常 |
| 普通左键短按 | 无 Fn down/up，无语音触发 |
| 按住后拖动超过容差，再移回 | 这次按住始终不触发 |
| 原地按住超过设定时间后松开 | 合成 Fn 回读通常增加 2；观察 当前语音软件 是否开始并停止 |
| 触发后拖动 | 发送 Fn up，观察 当前语音软件 是否停止 |
| 触控板物理按下重复测试 | 验证相同事件路径；轻点不保证等同 |

“复制诊断记录”把本次会话最近 100 条状态复制到剪贴板；不写键入文本、录音内容或鼠标坐标到日志文件。菜单打开会取消当前手势，因此应先完成按住/松开测试，再打开菜单查看诊断。

## Fn 不响应时的最小替代方案

保留同一个长按检测器，只替换输出事件。前提是 **当前语音软件 确实允许设置普通按键/组合键作为语音快捷键**；此能力尚需在实际版本中确认。

1. 先在 当前语音软件 中设置一个未被其他应用占用的快捷键，确认真实键盘能触发它。
2. MouseVoice 菜单选择“打开配置文件”，把 `shortcutKeyCode` 和 `shortcutModifiers` 改成相同的按键。
3. 点击“重新载入配置”，然后按 当前语音软件 的行为选择以下模式，最后重新启用：
   - **快捷键：按住 / 松开**（`shortcutHold`）：达到设定时间发送快捷键按下，鼠标松开发送快捷键释放，适合按住说话。
   - **快捷键：开始 / 结束各点一次**（`shortcutToggle`）：达到设定时间点按一次快捷键，鼠标松开再点按一次，适合开关式录音。必须先确认 当前语音软件 已停止录音；否则开关状态可能反向。它没有读取 当前语音软件 的录音状态。

初始替代键是 **F18（键码 79，无修饰键）**，未在 当前语音软件 中做任何设置。若不方便录入 F18，可用键盘能够实际按出的组合，例如 **Control + Option + Space**：

```json
{
  "holdSeconds": 0.5,
  "movementTolerancePoints": 6,
  "maximumHoldSeconds": 60,
  "mode": "shortcutHold",
  "shortcutKeyCode": 49,
  "shortcutModifiers": ["control", "option"]
}
```

这是配置示例，不保证该组合在你的系统中空闲。两边必须配置成同一组合。常用物理虚拟键码：Space=49、F18=79、F19=80、F20=90。修饰键支持 `control`、`option`、`shift`、`command`。不使用 Fn 作为替代组合的修饰键。模式切换和配置载入都会暂停监听。

运行时配置保存于 `~/Library/Application Support/MouseVoice/config.json`。源目录的 `config.example.json` 仅为示例，不会自动覆盖已有配置。错误配置会阻止启用，并在菜单中显示原因。

## 从源码构建

要求 macOS 13 或以上，以及 Apple Command Line Tools（包含 Swift 编译器）。本次附带 app 是在本机 Apple Silicon 上构建的 arm64 版本；Intel Mac 可从源码重新构建。未跨机验证最低系统版本。

在终端进入本目录，然后执行：

```sh
bash build.sh
ditto -x -k MouseVoice.app.zip .
open MouseVoice.app
```

不需要 Xcode 工程、Swift Package 下载或联网。脚本在临时目录构建 `.app`、使用本地 ad-hoc 签名并严格验证，然后只输出排除 Finder 元数据的 `MouseVoice.app.zip`，避免构建目录产生第二个可见应用；没有 Apple Developer 分发签名或公证。重新构建、移动路径后，macOS 可能要求重新授权。建议先放到最终位置再授权。对外分发到其他 Mac 的 Gatekeeper 行为未验证。

自动检查：

```sh
bash test.sh
./MouseVoice.app/Contents/MacOS/MouseVoice --diagnose
./MouseVoice.app/Contents/MacOS/MouseVoice --smoke-test
```

`test.sh` 验证状态机和键盘事件结构，不实际注入输入。`--diagnose` 只读取权限、不弹窗、不启动监听、不发送事件。终端调用可能使用终端或宿主的权限身份，**不能代替 Finder 启动后菜单显示的 app 权限结果**。`--smoke-test` 创建菜单栏应用，保持暂停，2 秒后退出；会正常创建默认配置。

## 文件

- `Sources/HoldDetector.swift`：可独立测试的长按/拖动状态机。
- `Sources/KeyOutput.swift`：Fn 和快捷键成对事件生成、投递及配置校验。
- `Sources/main.swift`：菜单栏、权限入口、全局被动监听和释放处理。
- `Tests/main.swift`：不发送输入的逻辑测试。
- `build.sh` / `test.sh`：构建与检查；`Info.plist`：应用元数据。

## API 依据

- [Apple：CGEventFlags（包含 Fn 标记）](https://developer.apple.com/documentation/coregraphics/cgeventflags)
- [Apple：flagsChanged](https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged)
- [Apple：创建键盘事件](https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:))
- [Apple：创建事件监听器](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))

同时参照本机 Apple SDK 的 `CGEvent.h` 权限预检/请求函数和 `HIToolbox/Events.h` 的 Fn/F18 键码定义。

## 0.3 更新与本机安装

- 应用安装于本机 `/Applications/MouseVoice.app`，源码即本仓库。
- 已加入原创鼠标与麦克风融合图标，资源位于 `Resources`。
- 监听位置改为 HID 入口：本机实测 Fn 会在后续 session 监听位置之前被处理，因此 session 回读缺失不能证明未发送。
- `--enable` 启动参数用于立即请求所需权限并启用；`--diagnostics` 输出本次状态到标准输出，不记录输入文字。正常双击会恢复上次明确选择的开关状态；首次运行默认暂停。休眠或会话切换仍会暂时暂停。
- `bash test-system.sh` 会打开临时窗口、投递全局鼠标与 Fn 事件，验证短按、长按、拖动及释放。会触发当前系统 Fn 绑定，运行前应知悉。
- 本地 ad-hoc 签名在重新构建后变化，旧权限可能需移除并重新添加；不代表应用已具备公证分发条件。

0.3 版菜单栏改为与应用 Logo 呼应的黑白模板图标，日常菜单只保留开关、长按时间、设置与诊断、退出；默认长按 0.5 秒。菜单栏模板图标会随系统浅色/深色外观自动显示为黑色或白色。
