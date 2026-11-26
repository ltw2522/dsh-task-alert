# ============================================================================
#  dsh-task-alert —— 桌面提示卡 helper（PowerShell 7 / WinForms）
# ----------------------------------------------------------------------------
#  作用：给 DSH（DeepSeek Harness）兜一个「原生置顶提示卡」。
#        DSH 自己只能往网页里塞 DOM，用户切去打游戏时看不见任何东西；
#        本脚本是独立进程的 WinForms 窗口，属于系统级浮窗，压在所有窗口之上。
#
#  通信协议（stdin / stdout 各一行 JSON，UTF-8）：
#    Host -> helper:
#      {"cmd":"ping"}
#      {"cmd":"notify","kind":"done|ask|error","title":"...","body":"...","key":"..."}
#      {"cmd":"close","key":"..."}
#      {"cmd":"settings"}
#      {"cmd":"quit"}
#    helper -> Host:
#      {"event":"ready","settingsPath":"...","hotkey":"Ctrl+Alt+A","hotkeyOk":true}
#      {"event":"action","action":"return|close","kind":"done","key":"...","time":123}
#      {"event":"settings-saved","settings":{...}}
#      {"event":"error","message":"..."}
#
#  生命周期：常驻。Host 插件在激活时就把它拉起来并预热（WinForms 首次加载
#            要约 600~900 ms，冷启动弹卡会明显延迟，所以必须预热）。
#            stdin 关闭（Host 进程没了）后自动退出。
#
#  用法（人工自测）：
#    pwsh -STA -File toast.ps1 -SelfTest        # 弹两张演示卡，8 秒后自己关
#    pwsh -STA -File toast.ps1 -SettingsOnly    # 只开设置窗口
# ============================================================================

[CmdletBinding()]
param(
    # 配置文件路径（Host 侧传入，缺省落在用户目录下的 .dsh\task-alert）
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.dsh\task-alert\settings.json'),
    # 自测：弹两张示例卡后退出，用于验证外观与点击
    [switch]$SelfTest,
    # 自测时卡片停留秒数（默认 8 秒，方便拍屏核对）
    [int]$SelfTestHold = 8,
    # 只开设置窗口（不常驻监听 stdin）
    [switch]$SettingsOnly
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  0. 输出纪律：stdout 只允许 JSON 行，任何 Write-Host 都会污染协议
# ---------------------------------------------------------------------------
# 控制台编码统一成 UTF-8：Host 按 UTF-8 收发 JSON，若这里用系统代码页（936/GBK），
# 中文标题会在传输途中被破坏，ConvertFrom-Json 直接失败。
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

$script:StdoutLock = [object]::new()

function Write-Json {
    # 向 Host 输出一行 JSON（加锁，避免多线程写乱行）
    param([hashtable]$Payload)
    $line = ($Payload | ConvertTo-Json -Compress -Depth 8)
    [System.Threading.Monitor]::Enter($script:StdoutLock)
    try {
        [Console]::Out.WriteLine($line)
        [Console]::Out.Flush()
    }
    finally { [System.Threading.Monitor]::Exit($script:StdoutLock) }
}

# ---------------------------------------------------------------------------
#  1. 加载界面程序集
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# System.Media 在 Windows Desktop 运行时里，失败也不致命（提示音降级为蜂鸣）
$script:HasMedia = $true
try { Add-Type -AssemblyName System.Windows.Extensions -ErrorAction Stop } catch { $script:HasMedia = $false }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
#  2. Win32 互操作：置顶、抢前台、全局热键、圆角窗体基类
# ---------------------------------------------------------------------------
if (-not ('DshAlert.Native' -as [type])) {
    # PowerShell 7 的 Add-Type 一旦显式传 -ReferencedAssemblies，就会顶掉它默认的
    # 引用集，于是 using System.Windows.Forms 报 CS0234、继承 Form 报 CS0012、
    # ConcurrentQueue 报 CS1069。正确做法是拿 $PSHOME\ref 下那套参考程序集
    # （PowerShell 7 自带，176 个）当基底，再补两个 WinForms/Drawing 运行期程序集。
    $refAsm = @(
        Get-ChildItem (Join-Path $PSHOME 'ref') -Filter *.dll -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    ) + @(
        # OOP WinForms 需要的运行期程序集：Forms / Drawing / ComponentModel 整族全带上
        # （少一个 System.Windows.Forms.Primitives 就报 CS1069 找不到 Message 类型）
        Get-ChildItem $PSHOME -Filter 'System.Windows.Forms*.dll' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        Get-ChildItem $PSHOME -Filter 'System.Drawing*.dll' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        Get-ChildItem $PSHOME -Filter 'System.ComponentModel*.dll' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        Get-ChildItem $PSHOME -Filter 'System.Private.Windows*.dll' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
    $refAsm = $refAsm | Where-Object { $_ } | Select-Object -Unique
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DshAlert
{
    public static class Native
    {
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
        [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        // 播放 wav：SND_ASYNC 不阻塞 UI 线程，SND_FILENAME 按路径，SND_NODEFAULT 找不到文件就静音
        [DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool PlaySound(string pszSound, IntPtr hmod, uint fdwSound);
        public const uint SND_ASYNC = 0x0001;
        public const uint SND_FILENAME = 0x00020000;
        public const uint SND_NODEFAULT = 0x0002;

        // 当前前台窗口属于给定进程集合之一吗？（判断「用户是不是正看着 DSH」）
        public static bool IsForegroundProcessIn(int[] pids)
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero || pids == null) return false;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            for (int i = 0; i < pids.Length; i++) { if ((uint)pids[i] == pid) return true; }
            return false;
        }

        public const int SW_RESTORE = 9;
        public const int SW_SHOW = 5;
        public const byte VK_MENU = 0x12;       // Alt
        public const uint KEYEVENTF_KEYUP = 0x0002;

        [StructLayout(LayoutKind.Sequential)]
        public struct FLASHWINFO
        {
            public uint cbSize;
            public IntPtr hwnd;
            public uint dwFlags;
            public uint uCount;
            public uint dwTimeout;
        }

        // 闪烁任务栏按钮（抢前台彻底失败时的兜底，至少让人看见）
        public static void Flash(IntPtr hWnd)
        {
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize = (uint)Marshal.SizeOf(fi);
            fi.hwnd = hWnd;
            fi.dwFlags = 0x00000003 | 0x0000000C; // FLASHW_ALL | FLASHW_TIMERNOFG
            fi.uCount = 3;
            fi.dwTimeout = 0;
            FlashWindowEx(ref fi);
        }

        // 释放 Windows 的「前台锁」：随便敲一下 Alt，本进程就获得设置前台的资格
        public static void ReleaseForegroundLock()
        {
            keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
            keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        }
    }

    // 提示卡窗体：不抢焦点（用户正在打游戏时不能把游戏切走）
    public class ToastForm : Form
    {
        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE：点击不激活
                cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW：不进 Alt+Tab
                return cp;
            }
        }
    }

    // 隐藏的消息窗：只用来接 WM_HOTKEY
    public class HotKeyForm : Form
    {
        public const int WM_HOTKEY = 0x0312;
        public event EventHandler HotKeyPressed;

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                EventHandler h = HotKeyPressed;
                if (h != null) h(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }
    }

    // stdin 行读取泵：PowerShell 里起 .NET Thread 跑 ScriptBlock 会因为没有
    // Runspace 直接崩（PSInvalidOperationException），所以这段必须用 C# 写。
    public class StdinPump
    {
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> Lines =
            new System.Collections.Concurrent.ConcurrentQueue<string>();
        public volatile bool Closed;
        private System.Threading.Thread thread;

        public void Start()
        {
            thread = new System.Threading.Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        private void Run()
        {
            try
            {
                // 必须显式用 UTF-8 读 stdin：Host 侧按 UTF-8 写 JSON，
                // 默认按系统代码页解码会把中文变成乱码导致 JSON 解析失败。
                var reader = new System.IO.StreamReader(
                    System.Console.OpenStandardInput(),
                    new System.Text.UTF8Encoding(false),
                    false);
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (line.Trim().Length > 0) Lines.Enqueue(line);
                }
            }
            catch { }
            Closed = true;
        }
    }
}
'@ -ReferencedAssemblies $refAsm
}

# ---------------------------------------------------------------------------
#  3. 配置：默认值 + 读写（Host 与 helper 共用同一个 JSON）
# ---------------------------------------------------------------------------
function Get-DefaultSettings {
    # 返回一份全新的默认配置（哈希表，方便按键覆盖）
    @{
        enabled          = $true                        # 总开关
        notifyOnDone     = $true                        # 一轮跑完是否弹
        notifyOnAsk      = $true                        # 有选项/审批待选是否弹
        anchor           = 'top-right'                  # 九宫格锚点
        marginX          = 24                           # 距屏幕左右边距（像素）
        marginY          = 24                           # 距屏幕上下边距（像素）
        width            = 420                          # 卡片宽度（像素）
        gap              = 10                           # 多张卡之间的间距
        bgColor          = '#1E2026F0'                   # 背景色（#RRGGBB 或 #RRGGBBAA）
        titleColor       = '#FFFFFF'                    # 标题文字色
        bodyColor        = '#C9CDD6'                    # 正文文字色
        accentColor      = '#4C8DFF'                    # 强调色（按钮/徽标/描边）
        opacity          = 1.0                         # 整卡不透明度 0.35~1.0
        durationSec      = 0                            # 自动消失秒数，0 = 不自动关
        sound            = 'asterisk'                   # none|asterisk|exclamation|beep|question|custom
        soundFile        = ''                           # sound=custom 时的 wav 路径
        soundOnDone      = $true                        # 完成时响
        soundOnAsk       = $true                        # 待选时响
        suppressWhenFocused = $false                    # DSH 已在前台时不弹
        hotkey           = 'Ctrl+Alt+A'                 # 打开设置窗口的全局热键
        dshUrl           = 'http://127.0.0.1:19333'     # 找不到 DSH 窗口时的兜底 URL
    }
}

function Read-Settings {
    # 读盘并合并默认值；文件坏了就用默认值，绝不因此崩掉 helper
    $s = Get-DefaultSettings
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $loaded = $raw | ConvertFrom-Json -AsHashtable
                foreach ($k in @($s.Keys)) {
                    if ($loaded.ContainsKey($k) -and $null -ne $loaded[$k]) { $s[$k] = $loaded[$k] }
                }
            }
        }
    }
    catch { Write-Json @{ event = 'error'; message = ("读取配置失败：" + $_.Exception.Message) } }
    return $s
}

function Save-Settings {
    # 落盘（UTF-8 无 BOM，目录不存在就建）
    param([hashtable]$Settings)
    try {
        $dir = [System.IO.Path]::GetDirectoryName($SettingsPath)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
        return $true
    }
    catch {
        Write-Json @{ event = 'error'; message = ("保存配置失败：" + $_.Exception.Message) }
        return $false
    }
}

# ---------------------------------------------------------------------------
#  4. 颜色工具
# ---------------------------------------------------------------------------
function Convert-HexToColor {
    # 支持 #RGB / #RRGGBB / #RRGGBBAA；解析不了就退回 fallback
    param([string]$Hex, [System.Drawing.Color]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return $Fallback }
    $h = $Hex.Trim().TrimStart('#')
    try {
        if ($h.Length -eq 3) {
            $h = '' + $h[0] + $h[0] + $h[1] + $h[1] + $h[2] + $h[2]
        }
        if ($h.Length -eq 6) { return [System.Drawing.ColorTranslator]::FromHtml('#' + $h) }
        if ($h.Length -eq 8) {
            $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
            $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
            $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
            $a = [Convert]::ToInt32($h.Substring(6, 2), 16)
            return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
        }
    }
    catch { }
    return $Fallback
}

# ---------------------------------------------------------------------------
#  5. 提示音
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  5.1 提示音目录（唯一真源：播放与设置下拉都从这里取，避免两处列表走偏）
# ---------------------------------------------------------------------------
function Get-SoundCatalog {
    # 每条：id 存进配置；label 显示在设置窗口；file 为 %WINDIR%\Media 下的 wav
    # 之所以不再用 SystemSounds.Asterisk/Exclamation/Question：
    # 这三个都发同一个「默认提示音」——用户系统声音方案里被映射到同一个 wav 时，
    # 选哪个听起来都一模一样（实测就是这个问题）。所以改成直接点名具体 wav。
    $media = Join-Path $env:WINDIR 'Media'
    return @(
        @{ id = 'none';    label = '无（不响）';           file = $null },
        @{ id = 'chime';   label = '清脆·风铃';            file = (Join-Path $media 'chimes.wav') },
        @{ id = 'notify';  label = '系统·通知';            file = (Join-Path $media 'Windows Notify System Generic.wav') },
        @{ id = 'ding';    label = '轻响·叮';              file = (Join-Path $media 'Windows Ding.wav') },
        @{ id = 'tada';    label = '完成·号角';            file = (Join-Path $media 'tada.wav') },
        @{ id = 'alarm';   label = '闹钟·急促';            file = (Join-Path $media 'Alarm01.wav') },
        @{ id = 'stop';    label = '警示·停止';            file = (Join-Path $media 'Windows Critical Stop.wav') },
        @{ id = 'beep';    label = '合成·哔哔（不依赖文件）'; file = $null },
        @{ id = 'custom';  label = '自定义 wav';           file = $null }
    )
}

function Get-SoundId {
    # 老配置值兼容：asterisk/exclamation/question 是上一版的 id，映射到新 id
    param([string]$Id)
    switch ([string]$Id) {
        'asterisk'    { return 'notify' }
        'exclamation' { return 'alarm' }
        'question'    { return 'ding' }
        ''            { return 'notify' }
        default       { return [string]$Id }
    }
}

function Play-WavFile {
    # 异步播放 wav（SND_ASYNC 立即返回，不会卡住卡片/设置窗口）
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $flags = [uint32]([DshAlert.Native]::SND_ASYNC -bor [DshAlert.Native]::SND_FILENAME -bor [DshAlert.Native]::SND_NODEFAULT)
        return [DshAlert.Native]::PlaySound($Path, [IntPtr]::Zero, $flags)
    }
    catch { return $false }
}

function New-ToneWavBytes {
    # 现场合成一段 16bit/单声道 wav（内存里），给「合成·哔哔」用：
    # 不依赖任何系统文件，任何机器上听起来都一致。
    param([int[]]$Freq, [int[]]$Ms, [int]$Rate = 22050, [double]$Amp = 0.32)
    $samples = New-Object System.Collections.Generic.List[int16]
    for ($i = 0; $i -lt $Freq.Count; $i++) {
        $f = $Freq[$i]
        $n = [int]($Rate * ($Ms[$i] / 1000.0))
        if ($f -le 0) {
            # 0 表示静音段
            for ($k = 0; $k -lt $n; $k++) { $samples.Add(0) }
            continue
        }
        for ($k = 0; $k -lt $n; $k++) {
            # 两端各 8ms 渐入渐出，避免爆音
            $env = 1.0
            $edge = [int]($Rate * 0.008)
            if ($k -lt $edge) { $env = $k / [double]$edge }
            elseif ($k -gt ($n - $edge)) { $env = [Math]::Max(0.0, ($n - $k) / [double]$edge) }
            $v = [Math]::Sin(2 * [Math]::PI * $f * $k / $Rate) * $Amp * $env
            $samples.Add([int16]([Math]::Round($v * 32767)))
        }
    }
    $dataLen = $samples.Count * 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
    $bw.Write([int32](36 + $dataLen))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $bw.Write([int32]16)          # fmt 块长度
    $bw.Write([int16]1)           # PCM
    $bw.Write([int16]1)           # 单声道
    $bw.Write([int32]$Rate)
    $bw.Write([int32]($Rate * 2)) # 字节率
    $bw.Write([int16]2)           # 块对齐
    $bw.Write([int16]16)          # 位深
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
    $bw.Write([int32]$dataLen)
    foreach ($sv in $samples) { $bw.Write([int16]$sv) }
    $bw.Flush()
    return $ms.ToArray()
}

function Play-BeepPattern {
    # 两短一长的合成音；SoundPlayer 异步播放，并把播放器挂在 script 作用域防 GC
    try {
        $bytes = New-ToneWavBytes -Freq @(880, 0, 1180, 0, 880) -Ms @(110, 60, 150, 60, 110)
        $stream = New-Object System.IO.MemoryStream(, $bytes)
        $player = New-Object System.Media.SoundPlayer($stream)
        $player.Play()
        $script:SoundPlayer = $player   # 保活，否则播一半就被回收
        return $true
    }
    catch {
        try { [Console]::Beep(880, 120) } catch { }
        return $false
    }
}

function Play-AlertSound {
    # 按配置播放提示音；任何异常都吞掉（声音失败不影响卡片）
    param([string]$Kind)
    $s = $script:Settings
    if ($Kind -eq 'done' -and -not $s.soundOnDone) { return }
    if ($Kind -eq 'ask' -and -not $s.soundOnAsk) { return }
    $id = Get-SoundId ([string]$s.sound)
    try {
        switch ($id) {
            'none' { return }
            'beep' { [void](Play-BeepPattern); return }
            'custom' {
                # 自定义 wav 优先；文件丢了就退回「系统·通知」，别静默失败
                if ($s.soundFile -and (Play-WavFile ([string]$s.soundFile))) { return }
                $fallback = (Get-SoundCatalog | Where-Object { $_.id -eq 'notify' } | Select-Object -First 1).file
                if (-not (Play-WavFile $fallback)) { [void](Play-BeepPattern) }
                return
            }
            default {
                $item = Get-SoundCatalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
                if ($item -and (Play-WavFile $item.file)) { return }
                # 目录里没有这个 id，或 wav 不在机器上 → 合成音兜底
                [void](Play-BeepPattern)
            }
        }
    }
    catch {
        try { [Console]::Beep(880, 120) } catch { }
    }
}

# ---------------------------------------------------------------------------
#  6. 返回 DSH：找窗口 → 还原 → 抢前台
# ---------------------------------------------------------------------------
function Find-DshWindow {
    # 依次尝试：
    #   1) 进程名含 DeepSeek / dsh 且有主窗口句柄的进程（DSH 桌面端）
    #   2) 标题含 DeepSeek Harness 的任何顶层窗口（万一被别的壳包着）
    param([string]$Url)
    $candidates = @()
    try {
        $candidates += Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and
            ($_.ProcessName -like '*DeepSeek*' -or $_.ProcessName -like '*dsh*')
        }
    }
    catch { }
    foreach ($p in $candidates) {
        try {
            if ($p.MainWindowTitle -and $p.MainWindowTitle.Length -gt 0) { return [IntPtr]$p.MainWindowHandle }
        }
        catch { }
    }
    # 退一步：按标题找（Electron 应用标题恒以「— DeepSeek Harness」结尾）
    try {
        $byTitle = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like '*DeepSeek Harness*'
        }
        foreach ($p in $byTitle) { return [IntPtr]$p.MainWindowHandle }
    }
    catch { }
    return [IntPtr]::Zero
}

function Invoke-ReturnToDsh {
    # 把 DSH 窗口拉到前台；全失败则用浏览器打开 GUI URL（至少能看结果）
    param([string]$Url)
    $h = Find-DshWindow -Url $Url
    if ($h -eq [IntPtr]::Zero) {
        # 桌面端没开（或只有网页版）→ 直接把 Web GUI 的地址丢给默认浏览器
        try { Start-Process $Url } catch { }
        return $false
    }
    try {
        if ([DshAlert.Native]::IsIconic($h)) { [void][DshAlert.Native]::ShowWindow($h, [DshAlert.Native]::SW_RESTORE) }
        [void][DshAlert.Native]::ShowWindow($h, [DshAlert.Native]::SW_SHOW)
        [void][DshAlert.Native]::BringWindowToTop($h)
        if ([DshAlert.Native]::SetForegroundWindow($h)) { return $true }
        # 前台锁没放开：敲一下 Alt 再试
        [DshAlert.Native]::ReleaseForegroundLock()
        Start-Sleep -Milliseconds 60
        if ([DshAlert.Native]::SetForegroundWindow($h)) { return $true }
        # 还是不行：闪任务栏提示用户手动点
        [DshAlert.Native]::Flash($h)
        return $false
    }
    catch { return $false }
}

# ---------------------------------------------------------------------------
#  7. 提示卡
# ---------------------------------------------------------------------------
$script:Toasts = [System.Collections.ArrayList]::new()   # 每项是一个有序哈希表
$script:ToastsVersion = 0

function Get-ToastPalette {
    # 统一把配置里的字符串颜色换成 Color 对象
    $s = $script:Settings
    @{
        bg     = Convert-HexToColor $s.bgColor     ([System.Drawing.Color]::FromArgb(30, 32, 38))
        title  = Convert-HexToColor $s.titleColor  ([System.Drawing.Color]::White)
        body   = Convert-HexToColor $s.bodyColor   ([System.Drawing.Color]::FromArgb(201, 205, 214))
        accent = Convert-HexToColor $s.accentColor ([System.Drawing.Color]::FromArgb(76, 141, 255))
    }
}

function Set-RoundedRegion {
    # 给窗体套圆角（WinForms 没有原生圆角属性，只能算 Region）
    param([System.Windows.Forms.Form]$Form, [int]$Radius = 14)
    $w = $Form.Width; $h = $Form.Height
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    $old = $Form.Region
    $Form.Region = New-Object System.Drawing.Region($path)
    if ($old) { $old.Dispose() }
    $path.Dispose()
}

function Update-ToastLayout {
    # 按锚点重新排布所有卡片：顶部锚点向下堆，底部锚点向上堆
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $s = $script:Settings
    $w = [int]$s.width
    $gap = [int]$s.gap
    $mx = [int]$s.marginX
    $my = [int]$s.marginY
    $anchor = [string]$s.anchor
    $vertical = 'top'
    if ($anchor -like 'bottom*') { $vertical = 'bottom' }
    $horizontal = 'right'
    if ($anchor -like '*left') { $horizontal = 'left' }
    elseif ($anchor -like '*center') { $horizontal = 'center' }

    $i = 0
    foreach ($t in $script:Toasts) {
        $f = $t.Form
        if ($null -eq $f -or $f.IsDisposed) { $i++; continue }
        $h = $f.Height
        switch ($horizontal) {
            'left'   { $x = $wa.Left + $mx }
            'center' { $x = $wa.Left + [int](($wa.Width - $w) / 2) }
            default  { $x = $wa.Right - $mx - $w }
        }
        if ($vertical -eq 'bottom') {
            $y = $wa.Bottom - $my - $h - ($i * ($h + $gap))
        }
        else {
            $y = $wa.Top + $my + ($i * ($h + $gap))
        }
        $f.Location = New-Object System.Drawing.Point($x, $y)
        $i++
    }
}

function Remove-Toast {
    # 关闭并销毁一张卡
    param($Toast)
    if ($null -eq $Toast) { return }
    try {
        if ($Toast.Form -and -not $Toast.Form.IsDisposed) {
            if ($Toast.Timer) { $Toast.Timer.Stop(); $Toast.Timer.Dispose() }
            $Toast.Form.Hide()
            $Toast.Form.Dispose()
        }
    }
    catch { }
    [void]$script:Toasts.Remove($Toast)
    Update-ToastLayout
}

function Close-ToastByKey {
    # 按 key 关掉（Host 要求撤销时用）
    param([string]$Key)
    foreach ($t in @($script:Toasts)) {
        if ($t.Key -eq $Key) { Remove-Toast $t }
    }
}

function Show-Toast {
    # 构造并显示一张提示卡
    param(
        [string]$Kind = 'done',
        [string]$Title = '任务已完成',
        [string]$Body = '',
        [string]$Key = ''
    )
    $s = $script:Settings
    $pal = Get-ToastPalette
    # Form.BackColor 不接受带透明通道的颜色（会抛「控件不支持透明的背景色」），
    # 所以背景一律降为不透明 RGB，透明度统一交给 Form.Opacity 表达。
    $bgAlpha = [int]$pal.bg.A
    $pal.bg = [System.Drawing.Color]::FromArgb(255, $pal.bg.R, $pal.bg.G, $pal.bg.B)
    $w = [int]$s.width
    $h = 152

    # ---- 同一个 key 的旧卡先关掉，避免叠出两张一样的 ----
    if ($Key) { Close-ToastByKey -Key $Key }

    $form = New-Object DshAlert.ToastForm
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.Width = $w
    $form.Height = $h
    $form.BackColor = $pal.bg
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.Padding = New-Object System.Windows.Forms.Padding(0)
    # 不透明度：配置越界时钳到 0.35~1.0，太透明等于看不见；
    # 若配色本身带了 alpha，就乘进去，别做双层叠加（会发灰）。
    $op = [double]$s.opacity
    if ($op -lt 0.35) { $op = 0.35 }
    if ($op -gt 1.0) { $op = 1.0 }
    if ($bgAlpha -lt 255) { $op = [Math]::Round($op * ($bgAlpha / 255.0), 3) }
    $form.Opacity = $op

    # ---- 左侧强调色竖条：一眼区分「完成 / 待选 / 出错」 ----
    $barColor = $pal.accent
    if ($Kind -eq 'error') { $barColor = [System.Drawing.Color]::FromArgb(255, 96, 92) }
    if ($Kind -eq 'ask') { $barColor = [System.Drawing.Color]::FromArgb(255, 186, 66) }
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size(5, $h)
    $bar.BackColor = $barColor
    $form.Controls.Add($bar)

    # ---- 标题 ----
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.AutoSize = $false
    $lblTitle.Location = New-Object System.Drawing.Point(20, 16)
    $lblTitle.Size = New-Object System.Drawing.Size(($w - 40), 30)
    $lblTitle.Text = $Title
    $lblTitle.ForeColor = $pal.title
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12.5, [System.Drawing.FontStyle]::Bold)
    $lblTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblTitle.UseMnemonic = $false
    $form.Controls.Add($lblTitle)

    # ---- 正文（最多 3 行，超出省略） ----
    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.AutoSize = $false
    $lblBody.Location = New-Object System.Drawing.Point(20, 48)
    $lblBody.Size = New-Object System.Drawing.Size(($w - 40), 52)
    $lblBody.Text = $Body
    $lblBody.ForeColor = $pal.body
    $lblBody.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $lblBody.BackColor = [System.Drawing.Color]::Transparent
    $lblBody.UseMnemonic = $false
    $form.Controls.Add($lblBody)

    # ---- 「返回 DSH」主按钮 ----
    $btnGo = New-Object System.Windows.Forms.Button
    $btnGo.Text = '返回 DSH'
    $btnGo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $btnGo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnGo.FlatAppearance.BorderSize = 0
    $btnGo.BackColor = $pal.accent
    $btnGo.ForeColor = [System.Drawing.Color]::White
    $btnGo.Size = New-Object System.Drawing.Size(104, 32)
    $btnGo.Location = New-Object System.Drawing.Point(($w - 20 - 72 - 8 - 104), ($h - 16 - 32))
    $btnGo.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnGo)

    # ---- 「关闭」次按钮 ----
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '关闭'
    $btnClose.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnClose.FlatAppearance.BorderSize = 1
    $btnClose.FlatAppearance.BorderColor = $pal.body
    # 注意：标准 Button 不支持透明背景（会抛「控件不支持透明的背景色」），
    # 只能填和卡片一致的底色来伪装透明。
    $btnClose.BackColor = $pal.bg
    $btnClose.ForeColor = $pal.body
    $btnClose.Size = New-Object System.Drawing.Size(72, 32)
    $btnClose.Location = New-Object System.Drawing.Point(($w - 20 - 72), ($h - 16 - 32))
    $btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($btnClose)

    # ---- 右上角齿轮：打开设置 ----
    $lblGear = New-Object System.Windows.Forms.Label
    $lblGear.AutoSize = $false
    $lblGear.Text = [char]0x2699   # ⚙
    $lblGear.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lblGear.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 11)
    $lblGear.ForeColor = $pal.body
    $lblGear.BackColor = [System.Drawing.Color]::Transparent
    $lblGear.Size = New-Object System.Drawing.Size(24, 24)
    $lblGear.Location = New-Object System.Drawing.Point(($w - 34), 6)
    $lblGear.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($lblGear)

    # ---- 卡片对象（先建好，事件里要互相引用） ----
    $toast = [ordered]@{
        Key   = $Key
        Kind  = $Kind
        Form  = $form
        Timer = $null
    }

    # ---- 事件：关闭 ----
    $closeAction = {
        Write-Json @{ event = 'action'; action = 'close'; kind = $Kind; key = $Key; time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        Remove-Toast $toast
    }.GetNewClosure()

    # ---- 事件：返回 DSH ----
    $goAction = {
        Write-Json @{ event = 'action'; action = 'return'; kind = $Kind; key = $Key; time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        Remove-Toast $toast
        [void](Invoke-ReturnToDsh -Url $script:Settings.dshUrl)
    }.GetNewClosure()

    $btnClose.Add_Click($closeAction)
    $btnGo.Add_Click($goAction)
    # 点正文也算「返回 DSH」（大多数人的直觉：点卡片就是要看结果）
    $lblTitle.Add_Click($goAction)
    $lblBody.Add_Click($goAction)
    $bar.Add_Click($goAction)
    $lblGear.Add_Click({
        Show-SettingsWindow
    }.GetNewClosure())

    # ---- 拖动：无边框窗口必须自己实现 ----
    $dragStart = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:dragOffset = New-Object System.Drawing.Point($e.X, $e.Y)
        }
    }
    $dragMove = {
        param($sender, $e)
        if ($script:dragOffset -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $e.X - $script:dragOffset.X),
                ($form.Location.Y + $e.Y - $script:dragOffset.Y))
        }
    }
    foreach ($c in @($form, $lblTitle, $lblBody, $bar)) {
        $c.Add_MouseDown($dragStart)
        $c.Add_MouseMove($dragMove)
    }

    # ---- 圆角 + 显示 ----
    $form.Add_Shown({ Set-RoundedRegion -Form $form -Radius 14 }.GetNewClosure())
    [void]$script:Toasts.Add($toast)
    $form.Show()
    # 同 Show-SettingsWindow 里的原因：helper 是用 windowsHide 起的，进程第一次
    # ShowWindow 会被 STARTUPINFO 的 SW_HIDE 顶掉，必须显式再 ShowWindow(SW_SHOW)。
    [void][DshAlert.Native]::ShowWindow($form.Handle, [DshAlert.Native]::SW_SHOW)
    Set-RoundedRegion -Form $form -Radius 14
    Update-ToastLayout

    # ---- 自动消失 ----
    $dur = [int]$s.durationSec
    if ($dur -gt 0) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [Math]::Min($dur, 3600) * 1000
        $timer.Tag = $toast
        $timer.Add_Tick({
            param($sender, $e)
            $sender.Stop()
            Remove-Toast $sender.Tag
        })
        $toast.Timer = $timer
        $timer.Start()
    }

    # ---- 提示音 ----
    Play-AlertSound -Kind $Kind
}

# ---------------------------------------------------------------------------
#  8. 设置窗口
# ---------------------------------------------------------------------------
$script:SettingsForm = $null

function Show-SettingsWindow {
    # 已经开着就只是拉到前面，不重复开
    if ($script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
        # 已经被关掉但状态没清（例如上次构造中途抛异常）时，直接重建
        if ($script:SettingsForm.Visible -or $script:SettingsForm.Controls.Count -gt 0) {
            $script:SettingsForm.Activate()
            return
        }
        try { $script:SettingsForm.Dispose() } catch { }
        $script:SettingsForm = $null
    }
    # 构造过程包一层：任何异常都写到诊断文件 + 回写 Host，绝不留下一个空壳窗口
    try {
        New-SettingsWindow
    }
    catch {
        $detail = $_.Exception.Message + ' | ' + $_.ScriptStackTrace
        try { Add-Content -Path (Join-Path $env:TEMP 'dsh-task-alert-settings-error.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $detail) -Encoding utf8 } catch { }
        Write-Json @{ event = 'error'; message = ('打开设置窗口失败：' + $detail) }
        if ($script:SettingsForm) { try { $script:SettingsForm.Dispose() } catch { } ; $script:SettingsForm = $null }
        [void][System.Windows.Forms.MessageBox]::Show(('设置窗口没能打开：{0}' -f $_.Exception.Message), '桌面提示卡', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function New-SettingsWindow {
    $s = $script:Settings
    # GetNewClosure() 造出来的动态模块里，$script: 指的是模块自己的脚本作用域，
    # 那里根本没有 Settings —— 拿到的会是空值。所以先把哈希表引用捕获成普通变量，
    # 闭包里只认这个 $settingsRef（同一对象，改它就是改全局配置）。
    $settingsRef = $s
    $pal = Get-ToastPalette

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '桌面提示卡 · 设置'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(468, 596)
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $script:SettingsForm = $f

    $y = 14
    function New-RowLabel {
        # 行标签：默认贴左边、宽度 88（必须窄于 112 的控件起始 x，否则会盖住输入框）
        param([string]$Text, [int]$Top, [int]$Width = 88, [int]$Left = 18)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.AutoSize = $false
        $l.Location = New-Object System.Drawing.Point($Left, ($Top + 4))
        $l.Size = New-Object System.Drawing.Size($Width, 22)
        $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        return $l
    }

    # ---- 开关组 ----
    $chkEnabled = New-Object System.Windows.Forms.CheckBox
    $chkEnabled.Text = '启用桌面提示卡'
    $chkEnabled.Checked = [bool]$s.enabled
    $chkEnabled.Location = New-Object System.Drawing.Point(18, $y)
    $chkEnabled.Size = New-Object System.Drawing.Size(200, 24)
    $f.Controls.Add($chkEnabled)

    $chkDone = New-Object System.Windows.Forms.CheckBox
    $chkDone.Text = '任务跑完时弹卡'
    $chkDone.Checked = [bool]$s.notifyOnDone
    $chkDone.Location = New-Object System.Drawing.Point(230, $y)
    $chkDone.Size = New-Object System.Drawing.Size(150, 24)
    $f.Controls.Add($chkDone)

    $chkAsk = New-Object System.Windows.Forms.CheckBox
    $chkAsk.Text = '有选项待选时弹卡'
    $chkAsk.Checked = [bool]$s.notifyOnAsk
    $chkAsk.Location = New-Object System.Drawing.Point(230, ($y + 26))
    $chkAsk.Size = New-Object System.Drawing.Size(190, 24)
    $f.Controls.Add($chkAsk)

    $chkFocus = New-Object System.Windows.Forms.CheckBox
    $chkFocus.Text = 'DSH 已在前台时不弹'
    $chkFocus.Checked = [bool]$s.suppressWhenFocused
    $chkFocus.Location = New-Object System.Drawing.Point(18, ($y + 26))
    $chkFocus.Size = New-Object System.Drawing.Size(200, 24)
    $f.Controls.Add($chkFocus)
    $y += 62

    # ---- 颜色 ----
    $f.Controls.Add((New-RowLabel -Text '背景色' -Top $y))
    $tbBg = New-Object System.Windows.Forms.TextBox
    $tbBg.Text = [string]$s.bgColor
    $tbBg.Location = New-Object System.Drawing.Point(112, $y)
    $tbBg.Size = New-Object System.Drawing.Size(110, 24)
    $f.Controls.Add($tbBg)
    $btnBg = New-Object System.Windows.Forms.Button
    $btnBg.Text = '取色'
    $btnBg.Location = New-Object System.Drawing.Point(230, ($y - 1))
    $btnBg.Size = New-Object System.Drawing.Size(58, 26)
    $f.Controls.Add($btnBg)
    $btnBg.Add_Click({
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $dlg.Color = Convert-HexToColor $tbBg.Text ([System.Drawing.Color]::FromArgb(30, 32, 38))
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbBg.Text = ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
        }
    })

    $f.Controls.Add((New-RowLabel -Text '强调色' -Top ($y + 32)))
    $tbAccent = New-Object System.Windows.Forms.TextBox
    $tbAccent.Text = [string]$s.accentColor
    $tbAccent.Location = New-Object System.Drawing.Point(112, ($y + 32))
    $tbAccent.Size = New-Object System.Drawing.Size(110, 24)
    $f.Controls.Add($tbAccent)
    $btnAccent = New-Object System.Windows.Forms.Button
    $btnAccent.Text = '取色'
    $btnAccent.Location = New-Object System.Drawing.Point(230, ($y + 31))
    $btnAccent.Size = New-Object System.Drawing.Size(58, 26)
    $f.Controls.Add($btnAccent)
    $btnAccent.Add_Click({
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $dlg.Color = Convert-HexToColor $tbAccent.Text ([System.Drawing.Color]::FromArgb(76, 141, 255))
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbAccent.Text = ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
        }
    })
    $y += 68

    # ---- 不透明度 ----
    $f.Controls.Add((New-RowLabel -Text '不透明度' -Top $y))
    $tbOpacity = New-Object System.Windows.Forms.TrackBar
    $tbOpacity.Minimum = 35
    $tbOpacity.Maximum = 100
    $tbOpacity.TickFrequency = 5
    $tbOpacity.Value = [int]([double]$s.opacity * 100)
    $tbOpacity.Location = New-Object System.Drawing.Point(108, ($y - 4))
    $tbOpacity.Size = New-Object System.Drawing.Size(240, 45)
    $f.Controls.Add($tbOpacity)
    $lblOpacity = New-Object System.Windows.Forms.Label
    $lblOpacity.Text = ('{0}%' -f $tbOpacity.Value)
    $lblOpacity.Location = New-Object System.Drawing.Point(352, ($y + 4))
    $lblOpacity.Size = New-Object System.Drawing.Size(60, 22)
    $f.Controls.Add($lblOpacity)
    $tbOpacity.Add_Scroll({ $lblOpacity.Text = ('{0}%' -f $tbOpacity.Value) })
    $y += 52

    # ---- 弹出位置 ----
    $f.Controls.Add((New-RowLabel -Text '弹出位置' -Top $y))
    $cbAnchor = New-Object System.Windows.Forms.ComboBox
    $cbAnchor.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $items = @(
        @{ v = 'top-left'; t = '左上角' }, @{ v = 'top-center'; t = '顶部居中' }, @{ v = 'top-right'; t = '右上角' },
        @{ v = 'middle-left'; t = '左侧居中' }, @{ v = 'middle-center'; t = '屏幕正中' }, @{ v = 'middle-right'; t = '右侧居中' },
        @{ v = 'bottom-left'; t = '左下角' }, @{ v = 'bottom-center'; t = '底部居中' }, @{ v = 'bottom-right'; t = '右下角' }
    )
    foreach ($it in $items) { [void]$cbAnchor.Items.Add($it.t) }
    $idx = 2
    for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].v -eq [string]$s.anchor) { $idx = $i } }
    $cbAnchor.SelectedIndex = $idx
    $cbAnchor.Location = New-Object System.Drawing.Point(112, $y)
    $cbAnchor.Size = New-Object System.Drawing.Size(160, 24)
    $f.Controls.Add($cbAnchor)
    $y += 34

    # ---- 边距 / 宽度（三组控件挤一行，标签各自定位，互不重叠） ----
    $f.Controls.Add((New-RowLabel -Text '左右边距' -Top $y -Width 88 -Left 18))
    $numMX = New-Object System.Windows.Forms.NumericUpDown
    $numMX.Minimum = 0; $numMX.Maximum = 800; $numMX.Value = [int]$s.marginX
    $numMX.Location = New-Object System.Drawing.Point(112, $y)
    $numMX.Size = New-Object System.Drawing.Size(64, 24)
    $f.Controls.Add($numMX)

    $f.Controls.Add((New-RowLabel -Text '上下边距' -Top $y -Width 60 -Left 196))
    $numMY = New-Object System.Windows.Forms.NumericUpDown
    $numMY.Minimum = 0; $numMY.Maximum = 800; $numMY.Value = [int]$s.marginY
    $numMY.Location = New-Object System.Drawing.Point(258, $y)
    $numMY.Size = New-Object System.Drawing.Size(64, 24)
    $f.Controls.Add($numMY)

    $lbl3 = New-Object System.Windows.Forms.Label
    $lbl3.Text = '宽度'
    $lbl3.Location = New-Object System.Drawing.Point(336, ($y + 4))
    $lbl3.Size = New-Object System.Drawing.Size(36, 22)
    $f.Controls.Add($lbl3)
    $numW = New-Object System.Windows.Forms.NumericUpDown
    $numW.Minimum = 260; $numW.Maximum = 900; $numW.Increment = 10; $numW.Value = [int]$s.width
    $numW.Location = New-Object System.Drawing.Point(374, $y)
    $numW.Size = New-Object System.Drawing.Size(60, 24)
    $f.Controls.Add($numW)
    $y += 38

    # ---- 停留时长 ----
    $f.Controls.Add((New-RowLabel -Text '停留秒数(0永久)' -Top $y -Width 128 -Left 18))
    $numDur = New-Object System.Windows.Forms.NumericUpDown
    $numDur.Minimum = 0; $numDur.Maximum = 600; $numDur.Value = [int]$s.durationSec
    $numDur.Location = New-Object System.Drawing.Point(152, $y)
    $numDur.Size = New-Object System.Drawing.Size(70, 24)
    $f.Controls.Add($numDur)
    $y += 38

    # ---- 提示音（下拉项直接来自 Get-SoundCatalog，保证和播放逻辑一一对应）----
    $f.Controls.Add((New-RowLabel -Text '提示音' -Top $y))
    $cbSound = New-Object System.Windows.Forms.ComboBox
    $cbSound.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $sounds = @(Get-SoundCatalog | ForEach-Object { @{ v = $_.id; t = $_.label; file = $_.file } })
    foreach ($it in $sounds) { [void]$cbSound.Items.Add($it.t) }
    $currentId = Get-SoundId ([string]$s.sound)
    $sidx = 1
    for ($i = 0; $i -lt $sounds.Count; $i++) { if ($sounds[$i].v -eq $currentId) { $sidx = $i } }
    $cbSound.SelectedIndex = $sidx
    $cbSound.Location = New-Object System.Drawing.Point(112, $y)
    $cbSound.Size = New-Object System.Drawing.Size(190, 24)
    $f.Controls.Add($cbSound)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '试听'
    $btnTest.Location = New-Object System.Drawing.Point(310, ($y - 1))
    $btnTest.Size = New-Object System.Drawing.Size(58, 26)
    $f.Controls.Add($btnTest)

    $tbWav = New-Object System.Windows.Forms.TextBox
    $tbWav.Text = [string]$s.soundFile
    $tbWav.Location = New-Object System.Drawing.Point(112, ($y + 30))
    $tbWav.Size = New-Object System.Drawing.Size(256, 24)
    $f.Controls.Add($tbWav)
    $btnWav = New-Object System.Windows.Forms.Button
    $btnWav.Text = '选 wav'
    $btnWav.Location = New-Object System.Drawing.Point(374, ($y + 29))
    $btnWav.Size = New-Object System.Drawing.Size(74, 26)
    $f.Controls.Add($btnWav)
    $btnWav.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = '音频 (*.wav)|*.wav'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tbWav.Text = $dlg.FileName }
    })

    $chkSoundDone = New-Object System.Windows.Forms.CheckBox
    $chkSoundDone.Text = '完成时响'
    $chkSoundDone.Checked = [bool]$s.soundOnDone
    $chkSoundDone.Location = New-Object System.Drawing.Point(112, ($y + 58))
    $chkSoundDone.Size = New-Object System.Drawing.Size(110, 24)
    $f.Controls.Add($chkSoundDone)
    $chkSoundAsk = New-Object System.Windows.Forms.CheckBox
    $chkSoundAsk.Text = '待选时响'
    $chkSoundAsk.Checked = [bool]$s.soundOnAsk
    $chkSoundAsk.Location = New-Object System.Drawing.Point(228, ($y + 58))
    $chkSoundAsk.Size = New-Object System.Drawing.Size(110, 24)
    $f.Controls.Add($chkSoundAsk)
    $y += 92

    # ---- 全局热键（可换预设：默认组合常被别的软件占着，打不开设置就靠这里换）----
    $f.Controls.Add((New-RowLabel -Text '打开设置热键' -Top ($y + 2) -Width 88))
    $cbHotkey = New-Object System.Windows.Forms.ComboBox
    $cbHotkey.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $hotkeyPresets = @('Ctrl+Alt+A', 'Ctrl+Alt+Shift+A', 'Ctrl+Alt+B', 'Ctrl+Alt+C', 'Ctrl+Alt+F9', 'Ctrl+Alt+F10')
    foreach ($k in $hotkeyPresets) { [void]$cbHotkey.Items.Add($k) }
    $hIdx = $hotkeyPresets.IndexOf([string]$s.hotkey)
    if ($hIdx -lt 0) { $hIdx = 0 }
    $cbHotkey.SelectedIndex = $hIdx
    $cbHotkey.Location = New-Object System.Drawing.Point(112, $y)
    $cbHotkey.Size = New-Object System.Drawing.Size(150, 24)
    $f.Controls.Add($cbHotkey)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = ('生效中：{0} · 卡片右上角 ⚙ 也能开' -f $s.hotkey)
    $lblHint.Location = New-Object System.Drawing.Point(270, ($y + 3))
    $lblHint.Size = New-Object System.Drawing.Size(184, 40)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(110, 116, 128)
    $f.Controls.Add($lblHint)
    $y += 46

    # ---- 底部按钮 ----
    $applyToSettings = {
        # 把界面上的值写回 $script:Settings（唯一写入口，避免两处逻辑分叉）
        param([hashtable]$Target)
        $Target.enabled = [bool]$chkEnabled.Checked
        $Target.notifyOnDone = [bool]$chkDone.Checked
        $Target.notifyOnAsk = [bool]$chkAsk.Checked
        $Target.suppressWhenFocused = [bool]$chkFocus.Checked
        $Target.bgColor = $tbBg.Text.Trim()
        $Target.accentColor = $tbAccent.Text.Trim()
        $Target.opacity = [Math]::Round($tbOpacity.Value / 100.0, 3)
        $Target.anchor = $items[$cbAnchor.SelectedIndex].v
        $Target.marginX = [int]$numMX.Value
        $Target.marginY = [int]$numMY.Value
        $Target.width = [int]$numW.Value
        $Target.durationSec = [int]$numDur.Value
        $Target.sound = $sounds[$cbSound.SelectedIndex].v
        $Target.soundFile = $tbWav.Text.Trim()
        $Target.soundOnDone = [bool]$chkSoundDone.Checked
        $Target.soundOnAsk = [bool]$chkSoundAsk.Checked
        return $Target
    }.GetNewClosure()

    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = '预览卡片'
    $btnPreview.Location = New-Object System.Drawing.Point(18, $y)
    $btnPreview.Size = New-Object System.Drawing.Size(96, 32)
    $f.Controls.Add($btnPreview)
    $btnPreview.Add_Click({
        # 预览用「临时配置」：先拷一份当前界面值，套上去弹卡，再还原
        try {
            $snapshot = @{}
            foreach ($k in @($settingsRef.Keys)) { $snapshot[$k] = $settingsRef[$k] }
            [void](& $applyToSettings $settingsRef)
            Show-Toast -Kind 'done' -Title '提示卡预览' -Body '任务跑完时，就是这样一张卡：点卡片或「返回 DSH」直接切回 DSH，点「关闭」只收掉这张卡。' -Key 'preview'
            foreach ($k in @($snapshot.Keys)) { $settingsRef[$k] = $snapshot[$k] }
        }
        catch {
            Write-Json @{ event = 'error'; message = ('预览失败：' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace) }
        }
    }.GetNewClosure())

    $btnDefault = New-Object System.Windows.Forms.Button
    $btnDefault.Text = '恢复默认'
    $btnDefault.Location = New-Object System.Drawing.Point(124, $y)
    $btnDefault.Size = New-Object System.Drawing.Size(96, 32)
    $f.Controls.Add($btnDefault)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(250, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(88, 32)
    $f.Controls.Add($btnCancel)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存并应用'
    $btnSave.Location = New-Object System.Drawing.Point(346, $y)
    $btnSave.Size = New-Object System.Drawing.Size(104, 32)
    $f.Controls.Add($btnSave)

    $btnTest.Add_Click({
        $snapshot = @{}
        foreach ($k in @($settingsRef.Keys)) { $snapshot[$k] = $settingsRef[$k] }
        [void](& $applyToSettings $settingsRef)
        Play-AlertSound -Kind 'done'
        foreach ($k in @($snapshot.Keys)) { $settingsRef[$k] = $snapshot[$k] }
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $f.Close()
    })

    $btnDefault.Add_Click({
        $d = Get-DefaultSettings
        $tbBg.Text = $d.bgColor
        $tbAccent.Text = $d.accentColor
        $tbOpacity.Value = [int]([double]$d.opacity * 100)
        $lblOpacity.Text = ('{0}%' -f $tbOpacity.Value)
        $cbAnchor.SelectedIndex = 2
        $numMX.Value = $d.marginX
        $numMY.Value = $d.marginY
        $numW.Value = $d.width
        $numDur.Value = $d.durationSec
        $cbSound.SelectedIndex = 1
        $chkEnabled.Checked = $d.enabled
        $chkDone.Checked = $d.notifyOnDone
        $chkAsk.Checked = $d.notifyOnAsk
        $chkFocus.Checked = $d.suppressWhenFocused
        $chkSoundDone.Checked = $d.soundOnDone
        $chkSoundAsk.Checked = $d.soundOnAsk
        $tbWav.Text = $d.soundFile
        $cbHotkey.SelectedIndex = 0
    })

    $btnSave.Add_Click({
        # 保存 = 写回内存 + 落盘 + 通知 Host + 立刻按新外观重排现有卡片
        $wantHotkey = [string]$cbHotkey.SelectedItem
        [void](& $applyToSettings $settingsRef)
        # 热键单独处理：换组合要真的重注册，注册失败就提示并把界面拉回原值
        if ($wantHotkey -and $wantHotkey -ne [string]$settingsRef.hotkey) {
            if (Set-GlobalHotkey -Name $wantHotkey) {
                $lblHint.Text = ('生效中：{0} · 卡片右上角 ⚙ 也能开；改完点「保存并应用」' -f $wantHotkey)
            }
            else {
                [void][System.Windows.Forms.MessageBox]::Show(
                    ('热键 {0} 被别的软件占用了，没能注册上。请换一个组合再保存。' -f $wantHotkey),
                    '桌面提示卡', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                $hNow = $hotkeyPresets.IndexOf([string]$settingsRef.hotkey)
                if ($hNow -ge 0) { $cbHotkey.SelectedIndex = $hNow }
                Save-Settings -Settings $settingsRef
                return
            }
        }
        [void](Save-Settings -Settings $settingsRef)
        Write-Json @{ event = 'settings-saved'; settings = $settingsRef }
        Close-ToastByKey -Key 'preview'
        Update-ToastLayout
        $f.Close()
    }.GetNewClosure())

    $f.Add_FormClosed({
        $script:SettingsForm = $null
    })

    $f.Show()
    $f.Activate()
    # 关键：插件是用 windowsHide 起 helper 的，进程的 STARTUPINFO 带 SW_HIDE，
    # Windows 会把「本进程第一次 ShowWindow」的 nCmdShow 换成 SW_HIDE，
    # 于是 Show() 之后窗口其实是隐藏的（isWindowVisible=False，看着像没打开）。
    # 再显式 ShowWindow(SW_SHOW) 一次即可覆盖，第二次调用起 nCmdShow 就生效了。
    [void][DshAlert.Native]::ShowWindow($f.Handle, [DshAlert.Native]::SW_SHOW)
    $f.Activate()
}

# ---------------------------------------------------------------------------
#  9. 命令处理（全部在 UI 线程上跑，见第 10 节的定时泵）
# ---------------------------------------------------------------------------
function Invoke-Command {
    param([string]$Line)
    $msg = $null
    try { $msg = $Line | ConvertFrom-Json -AsHashtable }
    catch {
        Write-Json @{ event = 'error'; message = ('无法解析命令：' + $Line) }
        return
    }
    $cmd = [string]$msg['cmd']
    switch ($cmd) {
        'ping' {
            Write-Json @{
                event        = 'ready'
                settingsPath = $SettingsPath
                settings     = $script:Settings
                hotkey       = [string]$script:Settings.hotkey
                hotkeyOk     = [bool]$script:HotKeyOk
            }
        }
        'notify' {
            if (-not $script:Settings.enabled) { return }
            $kind = [string]$msg['kind']
            if ($kind -eq 'done' -and -not $script:Settings.notifyOnDone) { return }
            if ($kind -eq 'ask' -and -not $script:Settings.notifyOnAsk) { return }
            if ($script:Settings.suppressWhenFocused -and (Test-DshForeground)) { return }
            $title = [string]$msg['title']
            $body = [string]$msg['body']
            $key = [string]$msg['key']
            # Host 每次都会带当前 GUI 地址过来（端口可能变），比配置里的旧值可靠
            $liveUrl = [string]$msg['dshUrl']
            if (-not [string]::IsNullOrWhiteSpace($liveUrl)) { $script:Settings.dshUrl = $liveUrl }
            if ([string]::IsNullOrWhiteSpace($title)) { $title = '任务已完成' }
            Show-Toast -Kind $kind -Title $title -Body $body -Key $key
        }
        'close' { Close-ToastByKey -Key ([string]$msg['key']) }
        'settings' { Show-SettingsWindow }
        'quit' { Quit-Helper }
        default { Write-Json @{ event = 'error'; message = ('未知命令：' + $cmd) } }
    }
}

function Test-DshForeground {
    # 前台窗口是不是 DSH 自己（是的话说明用户正看着，按配置可以不弹）
    try { return [DshAlert.Native]::IsForegroundProcessIn([int[]]$script:DshPids) }
    catch { return $false }
}

function Update-DshPidCache {
    # 缓存 DSH 桌面端的进程号；每 3 秒刷新一次即可，没必要每拍都全表扫
    try {
        $ids = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -like '*DeepSeek*' } |
            Select-Object -ExpandProperty Id)
        if ($ids.Count -gt 0) { $script:DshPids = [int[]]$ids }
    }
    catch { }
}

function Quit-Helper {
    # 有序退出：先收卡，再停泵，最后结束消息循环
    foreach ($t in @($script:Toasts)) { Remove-Toast $t }
    if ($script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
        try { $script:SettingsForm.Dispose() } catch { }
    }
    try { [System.Windows.Forms.Application]::ExitThread() } catch { }
    exit 0
}

# ---------------------------------------------------------------------------
#  10. 启动：读配置 → 起 stdin 读线程 → 起 UI 泵 → 起热键
# ---------------------------------------------------------------------------
$script:Settings = Read-Settings
$script:DshPids = [int[]]@()
Update-DshPidCache

# stdin 读泵：阻塞式 ReadLine 不能放在 UI 线程，又不能用 PowerShell 起线程
# （没有 Runspace 会崩），所以用 C# 的 DshAlert.StdinPump 后台读，UI 侧轮询。
$script:Inbox = New-Object DshAlert.StdinPump
$script:Inbox.Start()

# UI 泵：每 40 ms 把 stdin 队列里的命令搬到 UI 线程执行
$script:Pump = New-Object System.Windows.Forms.Timer
$script:Pump.Interval = 40
$script:Pump.Add_Tick({
    [string]$line = ''
    $count = 0
    # 注意：队列在 pump.Lines 上，不是 pump 本身
    while ($script:Inbox.Lines.TryDequeue([ref]$line)) {
        try { Invoke-Command -Line $line }
        catch { Write-Json @{ event = 'error'; message = ('命令执行失败：' + $_.Exception.Message) } }
        $count++
        if ($count -ge 20) { break }   # 单拍限流，避免 UI 卡死
    }
    # stdin 已关闭且没有卡片残留 → 走人。
    # 但 -SettingsOnly 模式是「用户从快捷方式单独开的设置窗口」，没有 Host 连管道，
    # stdin 一开场就是 EOF；这种必须等用户关掉设置窗口才退出，否则窗口一闪就没。
    $shouldExit = $false
    if ($script:Inbox.Closed) {
        if ($SettingsOnly) { $shouldExit = ($null -eq $script:SettingsForm) }
        elseif ($script:Toasts.Count -eq 0) { $shouldExit = $true }
    }
    if ($shouldExit) {
        $script:Pump.Stop()
        [System.Windows.Forms.Application]::ExitThread()
    }
})

# 全局热键：优先用配置里的组合，被占用则依次尝试备用组合
# 为什么要有备用链：Ctrl+Alt+A 在很多机器上已被别的软件（录屏/输入法/显卡）占着，
# RegisterHotKey 会静默失败，用户就会觉得「设置打不开」。
function ConvertFrom-Hotkey {
    # 把 'Ctrl+Alt+Shift+A' 解析成 { m = 修饰位; k = 虚拟键码; name = 原串 }
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = 0
    $parts = @($Text -split '\+')
    foreach ($raw in $parts) {
        switch ($raw.Trim().ToUpperInvariant()) {
            'CTRL'   { $m = $m -bor 2 }   # MOD_CONTROL
            'ALT'    { $m = $m -bor 1 }   # MOD_ALT
            'SHIFT'  { $m = $m -bor 4 }   # MOD_SHIFT
            'WIN'    { $m = $m -bor 8 }   # MOD_WIN
        }
    }
    $keyName = ($parts[-1]).Trim().ToUpperInvariant()
    $vk = 0
    if ($keyName -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
    elseif ($keyName.Length -eq 1 -and $keyName -match '^[A-Z0-9]$') { $vk = [int][char]$keyName }
    if ($vk -eq 0 -or $m -eq 0) { return $null }
    return @{ m = $m; k = $vk; name = $Text }
}

function Register-HotkeyCandidate {
    # 试注册一个组合；成功返回 $true
    param([hashtable]$Combo)
    if (-not $Combo -or -not $script:HotKeyForm) { return $false }
    try {
        return [DshAlert.Native]::RegisterHotKey($script:HotKeyForm.Handle, 1, [uint32]$Combo.m, [uint32]$Combo.k)
    }
    catch { return $false }
}

function Set-GlobalHotkey {
    # 换一个热键组合：先撤旧的再注册新的；注册失败把旧组合还回去并返回 $false。
    # 设置窗口里改热键走这里，避免出现「配置写了但快捷键根本没生效」。
    param([string]$Name)
    $combo = ConvertFrom-Hotkey $Name
    if (-not $combo -or -not $script:HotKeyForm) { return $false }
    $prev = ConvertFrom-Hotkey ([string]$script:Settings.hotkey)
    try { [void][DshAlert.Native]::UnregisterHotKey($script:HotKeyForm.Handle, 1) } catch { }
    if ([DshAlert.Native]::RegisterHotKey($script:HotKeyForm.Handle, 1, [uint32]$combo.m, [uint32]$combo.k)) {
        $script:HotKeyOk = $true
        $script:Settings.hotkey = $combo.name
        return $true
    }
    # 新组合注册不上：把旧的注册回去，配置值保持不变
    if ($prev) { [void](Register-HotkeyCandidate $prev) }
    return $false
}

function Initialize-Hotkey {
    # 建隐藏窗体 + 首次注册（配置值优先，其次备用链）
    $form = New-Object DshAlert.HotKeyForm
    $form.ShowInTaskbar = $false
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $form.Opacity = 0
    $null = $form.Handle      # 强制创建句柄，隐藏窗体也能收 WM_HOTKEY
    $form.Add_HotKeyPressed({ Show-SettingsWindow })
    $null = $form.Show()
    $form.Hide()
    $script:HotKeyForm = $form
    $script:HotKeyOk = $false

    # 候选顺序：配置值 → Ctrl+Alt+A → Ctrl+Alt+Shift+A → Ctrl+Alt+B → Ctrl+Alt+F9
    $mods = New-Object System.Collections.Generic.List[object]
    $fromCfg = ConvertFrom-Hotkey ([string]$script:Settings.hotkey)
    if ($fromCfg) { $mods.Add($fromCfg) }
    foreach ($cand in @(
        @{ m = 3; k = 0x41; name = 'Ctrl+Alt+A' },
        @{ m = 7; k = 0x41; name = 'Ctrl+Alt+Shift+A' },
        @{ m = 3; k = 0x42; name = 'Ctrl+Alt+B' },
        @{ m = 3; k = 0x78; name = 'Ctrl+Alt+F9' }
    )) {
        if (-not ($mods | Where-Object { $_.name -eq $cand.name })) { $mods.Add($cand) }
    }
    foreach ($hk in $mods) {
        if (Register-HotkeyCandidate $hk) {
            $script:HotKeyOk = $true
            $script:Settings.hotkey = $hk.name
            break
        }
    }
}

Initialize-Hotkey

# 前台状态刷新定时器：每 1 秒看一次，每 3 拍才重扫一次进程表（代价可忽略）
$script:FgTimer = New-Object System.Windows.Forms.Timer
$script:FgTimer.Interval = 1000
$script:FgTick = 0
$script:FgTimer.Add_Tick({
    $script:FgTick++
    if (($script:FgTick % 3) -eq 1) { Update-DshPidCache }
})
$script:FgTimer.Start()

Write-Json @{
    event        = 'ready'
    settingsPath = $SettingsPath
    hotkey       = [string]$script:Settings.hotkey
    hotkeyOk     = [bool]$script:HotKeyOk
    pid          = $PID
}

# 未处理异常兜底：默认弹「Microsoft .NET」对话框会卡住整个 UI 线程，
# 这里改成把异常文本（含脚本行号）回写给 Host，然后继续跑。
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    $text = $e.Exception.ToString()
    Write-Json @{ event = 'error'; message = ('UI 线程异常：' + $text) }
})

# 自测模式：直接弹两张卡，8 秒后退出（人工看外观用）
if ($SelfTest) {
    Show-Toast -Kind 'done' -Title '✅ 任务完成' -Body '把 D:\dsh_workspace\demo 的报表跑完了，共 12 页。点这里或「返回 DSH」切回去看结果。' -Key 'selftest-1'
    Start-Sleep -Milliseconds 200
    Show-Toast -Kind 'ask' -Title '❓ 等待你选择' -Body '两个方案都可行：A 走本地缓存（快），B 走全量重算（准）。要我选哪个？' -Key 'selftest-2'
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = [Math]::Max(2, $SelfTestHold) * 1000
    $t.Add_Tick({ param($snd, $e) $snd.Stop(); Quit-Helper })
    $t.Start()
}

$script:Pump.Start()

# 只开设置窗口模式：开了就坐着
if ($SettingsOnly) {
    try { Show-SettingsWindow }
    catch { Write-Json @{ event = 'error'; message = ('打开设置窗口失败：' + $_.Exception.Message + ' | ' + $_.ScriptStackTrace) } }
}

[System.Windows.Forms.Application]::Run()


