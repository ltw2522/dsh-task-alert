# 桌面提示卡（dsh-task-alert）

## 它解决什么问题

DSH 跑一轮任务经常要几十秒到几十分钟。你切出去打游戏、看视频的时候，无法知道
这一轮什么时候结束、也不知道 DSH 是不是在等你选方案 —— 只能反复切窗口回去看。

这个插件在**任务跑完**或**有选项/审批等你处理**时，直接在屏幕角落弹一张原生卡片：

- 卡片是独立的 WinForms 置顶窗口，**盖在全屏游戏、最大化浏览器之上**；
- 卡片带 `WS_EX_NOACTIVATE`，**不会抢你的焦点**，游戏里该怎么动还怎么动；
- 两个按钮：「返回 DSH」（把 DSH 窗口切到前台）和「关闭」（收掉卡片）；
- 点卡片正文/标题/色条也等于「返回 DSH」，符合直觉。

## 工作原理

```
DSH Host 插件 (index.js)                  常驻助手 (assets/toast.ps1)
   agent/status: running→idle  ──notify──▶  WinForms 置顶卡片
   user-questions/request      ──notify──▶  （或排队、去重、按配置抑制）
   approval/request            ──notify──▶
                               ◀─action──  用户点了「返回 DSH / 关闭」
```

- `index.js` 只做三件事：监听 Host 事件、管理 helper 进程、解析一行一条的 JSON 协议。
- `assets/toast.ps1` 才是真正画卡片的地方：PowerShell 7 + WinForms，`-STA` 启动，
  用 `Application::Run()` 常驻，从 stdin 收指令、往 stdout 发事件。
- 配置只有一份：`%USERPROFILE%\.dsh\task-alert\settings.json`。卡片和设置窗口都读它，
  所以改完立刻生效，不用重启 DSH。

## 什么时候会弹

| 事件 | 卡片标题 | 说明 |
| --- | --- | --- |
| 一轮正常跑完 | ✅ 任务完成 | 子代理结束不弹，避免刷屏 |
| 这一轮出错/被拦截 | ⚠ 这一轮没跑通 | 正文写明 reason（error / blocked） |
| ask_user_question 待作答 | ❓ 等你选一下 | 正文带问题摘要与问题个数 |
| 工具审批待放行 | 🔐 等你授权 | 正文带工具名与授权原因 |

## 设置

按 **Ctrl+Alt+B**（可在设置里换成 Ctrl+Alt+A / Ctrl+Alt+Shift+A / Ctrl+Alt+C /
Ctrl+Alt+F9 / Ctrl+Alt+F10）打开设置窗口，或点卡片右上角的 ⚙；两者都打不开时，
双击插件目录里的 `open-settings.cmd`。可调项：

- 总开关；分别开关「完成弹」「待选弹」；「DSH 已在前台时不弹」
- 背景色、强调色；整卡不透明度
- 九宫格锚点（左上/上中/右上/左中/…/右下）、边距、卡片宽度
- 自动消失秒数（0 = 一直留着直到你点掉）
- 提示音：无 / 清脆·风铃 / 系统·通知 / 轻响·叮 / 完成·号角 / 闹钟·急促 /
  警示·停止 / 合成·哔哔 / 自定义 wav，可逐项试听
- 打开设置的热键组合
- 预览、恢复默认、保存并应用

## 已知边界

- 仅 Windows：卡片的置顶、抢前台、全局热键都依赖 user32。
- 「返回 DSH」先按进程名/窗口标题找 `DeepSeek Harness` 主窗口并切前台；找不到
  才退化成用浏览器打开 Host 每次随通知带过来的 GUI 地址（端口变了也不会打空）。
- helper 首次拉起需要 1~2 秒（PowerShell 启动 + Add-Type 编译）。插件加载后会
  主动预热，并每 30 秒心跳保活，所以热键平时是随时可用的。
- 如果你的游戏是**独占全屏**（不是无边框全屏），Windows 的 TopMost 也可能压不住，
  建议游戏里改成「无边框窗口」。
