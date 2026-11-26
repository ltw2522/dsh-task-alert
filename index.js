// ============================================================================
//  dsh-task-alert —— Host 半：监听「任务跑完」与「等你选择」，弹桌面原生提示卡
// ----------------------------------------------------------------------------
//  设计要点：
//  1. 提示卡不是网页元素，而是独立的 WinForms 置顶窗口 —— 这样用户全屏打游戏、
//     浏览器被最小化时照样能看到（页面内的 toast 在那种场景等于看不见）。
//  2. 真正的窗口逻辑全部在 assets/toast.ps1 里（PowerShell 7 + WinForms），
//     本文件只负责「进程管理 + 事件转发 + 一行一条 JSON 的协议解析」。
//  3. helper 常驻：首次需要弹卡时拉起，之后复用同一个进程，避免每次冷启动
//     （PowerShell 启动 + Add-Type 编译约 1~2 秒，弹卡不能等这么久）。
//  4. 弹/不弹、颜色、透明度、位置、提示音等判断全部由 helper 依据自己的
//     %USERPROFILE%\.dsh\task-alert\settings.json 决定，Host 不重复实现策略，
//     这样用户在设置窗口里改完立刻生效，不需要重启 DSH。
// ============================================================================

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Cordis 插件名（与 cordis.patch.yml 里的 id 不必相同，但保持一致好排查）。 */
export const name = 'task-alert'

// ---------------------------------------------------------------------------
//  路径与常量
// ---------------------------------------------------------------------------

/** 本插件根目录（ESM 下没有 __dirname，只能用 import.meta.url 反推）。 */
const PLUGIN_ROOT = dirname(fileURLToPath(import.meta.url))
/** WinForms helper 脚本的绝对路径。 */
const HELPER_SCRIPT = join(PLUGIN_ROOT, 'assets', 'toast.ps1')
/** 配置文件位置；helper 与设置窗口共用这一份，Host 侧只读不写。 */
const SETTINGS_PATH = join(homedir(), '.dsh', 'task-alert', 'settings.json')
/** helper 冷启动预算：超过这个时间还没 ready，就先别堵着调用方。 */
const READY_TIMEOUT_MS = 8000
/** 同一 key 的重复通知抑制窗口，防止连发两条一样的卡。 */
const DEDUPE_MS = 3000
/** 正文最大长度：卡片正文只有三行，超出部分在 helper 里本来也会被裁掉。 */
const BODY_LIMIT = 200

// ---------------------------------------------------------------------------
//  小工具
// ---------------------------------------------------------------------------

/** 把多行文本压成一行并截断，卡片标题/正文都不接受换行。 */
function oneLine(text, limit = BODY_LIMIT) {
  const flat = String(text ?? '')
    .replace(/\s+/g, ' ')
    .trim()
  return flat.length > limit ? `${flat.slice(0, limit - 1)}…` : flat
}

/** 取当前时间戳，仅用于日志与去重。 */
function nowMs() {
  return Date.now()
}

/** 在 DSH 日志里留痕；插件出错不应该把会话搞崩，所以全部吞掉异常。 */
function log(ctx, level, message) {
  try {
    ctx?.logger?.[level]?.(`[task-alert] ${message}`)
  } catch {
    // logger 不可用时静默：提示卡属于辅助功能，不该因为日志通道异常而中断主流程
  }
}

// ---------------------------------------------------------------------------
//  helper 进程封装
// ---------------------------------------------------------------------------

/**
 * 管理常驻的 PowerShell helper：
 * - ensure()：确保进程活着；首次调用会一路等到它输出 {"event":"ready"}
 * - notify()：下发一条弹卡指令
 * - dispose()：插件卸载时收尸
 */
class ToastHelper {
  constructor(ctx) {
    /** Cordis 上下文，仅用于日志。 */
    this.ctx = ctx
    /** 子进程句柄；null 表示当前没起或已退出。 */
    this.child = null
    /** 是否已经收到 ready（收到之前发指令会被排队）。 */
    this.ready = false
    /** 启动中的 Promise，避免并发触发时拉起多个进程。 */
    this.starting = null
    /** 已排队等待 ready 的指令。 */
    this.pending = []
    /** stdout 的半行缓冲：一行 JSON 可能被拆成多个 chunk。 */
    this.buffer = ''
    /** 最近一次下发过的 key，用于抑制重复通知。 */
    this.lastKeys = new Map()
    /** 插件是否已卸载；卸载后不再重启 helper。 */
    this.disposed = false
  }

  /**
   * 解析 helper 可执行文件：按顺序挑第一个真实存在的 pwsh。
   * 不能只写 'pwsh.exe' 就完事 —— Electron 主进程的 PATH 里不一定有
   * WindowsApps 那个别名，找不到就会 ENOENT，卡片永远不弹。
   */
  resolveShell() {
    if (process.platform !== 'win32') return 'pwsh'
    const candidates = [
      // 1) PATH 上的 pwsh（MSIX 别名或传统安装都会命中）
      'pwsh.exe',
      // 2) PowerShell 7 的常规安装位置（x64 / x86）
      'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
      'C:\\Program Files (x86)\\PowerShell\\7\\pwsh.exe',
      // 3) 当前用户级 MSIX 别名目录
      join(homedir(), 'AppData', 'Local', 'Microsoft', 'WindowsApps', 'pwsh.exe'),
    ]
    for (const candidate of candidates) {
      // 裸名字（pwsh.exe）没法用 existsSync 判断，直接放行交给 spawn 解析
      if (!candidate.includes('\\')) return candidate
      if (existsSync(candidate)) return candidate
    }
    // 都找不到就只能让 spawn 去 PATH 里再试一次；helper 依赖 PS7 的
    // $PSHOME\ref 参考程序集，退回 PowerShell 5.1 反而会编译失败，故不做 5.1 兜底。
    return 'pwsh.exe'
  }

  /** 确保 helper 在跑，并等到 ready。 */
  async ensure() {
    if (this.disposed) return false
    if (this.child && this.ready) return true
    if (this.starting) return this.starting

    this.starting = this.start().finally(() => {
      this.starting = null
    })
    return this.starting
  }

  /** 真正拉起进程并等待 ready。 */
  async start() {
    if (!existsSync(HELPER_SCRIPT)) {
      log(this.ctx, 'warn', `helper 脚本不存在：${HELPER_SCRIPT}`)
      return false
    }

    const shell = this.resolveShell()
    let child
    try {
      child = spawn(
        shell,
        // -STA 必须有：WinForms 的剪贴板/窗口消息在这套 helper 里按 STA 写的
        ['-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', HELPER_SCRIPT,
          '-SettingsPath', SETTINGS_PATH],
        {
          // stdin 用于 Host→helper 指令；stdout 用于 helper→Host 事件；stderr 只进日志
          stdio: ['pipe', 'pipe', 'pipe'],
          windowsHide: true,
        },
      )
    } catch (error) {
      log(this.ctx, 'warn', `helper 启动失败：${error?.message ?? error}`)
      return false
    }

    this.child = child
    this.ready = false
    this.buffer = ''

    // stdout：一行一条 JSON
    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk) => this.onStdout(chunk))
    // stderr：helper 的 PowerShell 报错，只做记录，不影响功能
    child.stderr?.setEncoding('utf8')
    child.stderr?.on('data', (chunk) => {
      const text = String(chunk).trim()
      if (text) log(this.ctx, 'debug', `helper stderr: ${oneLine(text, 300)}`)
    })
    // 进程没了：清状态，下一条通知会重新拉起（不主动重启，避免疯狂循环）
    child.on('exit', (code, signal) => {
      this.child = null
      this.ready = false
      if (!this.disposed) log(this.ctx, 'debug', `helper 退出 code=${code} signal=${signal}`)
    })
    child.on('error', (error) => {
      log(this.ctx, 'warn', `helper 进程错误：${error?.message ?? error}`)
    })

    // 等 ready：用轮询代替事件回调，逻辑更直白，超时也不会有悬挂的 Promise
    const deadline = nowMs() + READY_TIMEOUT_MS
    while (nowMs() < deadline) {
      if (this.ready) return true
      if (!this.child) return false
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    log(this.ctx, 'warn', `helper 在 ${READY_TIMEOUT_MS}ms 内没有 ready`)
    return this.ready
  }

  /** 处理 helper 的 stdout：拆行 → JSON → 分发。 */
  onStdout(chunk) {
    this.buffer += chunk
    let index
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).trim()
      this.buffer = this.buffer.slice(index + 1)
      if (!line) continue
      let event
      try {
        event = JSON.parse(line)
      } catch {
        // 非 JSON 行（例如 PowerShell 的 Write-Host 误输出）直接记日志跳过
        log(this.ctx, 'debug', `helper 非 JSON 输出：${oneLine(line, 200)}`)
        continue
      }
      this.onEvent(event)
    }
  }

  /** 分发 helper 事件。 */
  onEvent(event) {
    switch (event?.event) {
      case 'ready':
        this.ready = true
        // ready 之后把排队的指令统统发出去
        for (const command of this.pending.splice(0)) this.write(command)
        log(this.ctx, 'info', `helper 就绪 pid=${event.pid} 热键=${event.hotkey} 配置=${event.settingsPath}`)
        break
      case 'action':
        // 用户点了「返回 DSH」或「关闭」；窗口侧已经自己处理完，这里只留痕
        log(this.ctx, 'debug', `卡片动作：${event.action} kind=${event.kind} key=${event.key}`)
        break
      case 'settings-saved':
        log(this.ctx, 'info', '设置已保存，后续提示卡立即生效')
        break
      case 'error':
        log(this.ctx, 'warn', `helper 报错：${oneLine(event.message, 300)}`)
        break
      default:
        break
    }
  }

  /** 下发一条指令（未 ready 时排队）。 */
  write(command) {
    const child = this.child
    if (!child?.stdin?.writable) return false
    try {
      child.stdin.write(`${JSON.stringify(command)}\n`)
      return true
    } catch (error) {
      log(this.ctx, 'warn', `写入 helper 失败：${error?.message ?? error}`)
      return false
    }
  }

  /** 取当前 Web GUI 地址（取不到就返回空串，helper 会退回配置里的值）。 */
  currentDshUrl() {
    try {
      const web = this.ctx.get?.('webApp')
      const url = web?.getAdvertisedUrl?.()
      return typeof url === 'string' ? url : ''
    } catch {
      return ''
    }
  }

  /** 弹一张卡；kind 取 done / ask / error。 */
  async notify(payload) {
    if (this.disposed) return
    const key = String(payload.key ?? `${payload.kind}:${nowMs()}`)
    // 去重：同一个 key 在窗口期内只发一次
    const last = this.lastKeys.get(key) ?? 0
    if (nowMs() - last < DEDUPE_MS) return
    this.lastKeys.set(key, nowMs())
    // 顺手清掉过期 key，避免 Map 无限长
    if (this.lastKeys.size > 64) {
      for (const [k, t] of this.lastKeys) {
        if (nowMs() - t > DEDUPE_MS * 10) this.lastKeys.delete(k)
      }
    }

    const command = {
      cmd: 'notify',
      kind: payload.kind ?? 'done',
      title: oneLine(payload.title, 60),
      body: oneLine(payload.body),
      key,
      // 把当前 GUI 地址一起带上：端口每次启动都可能变，helper 里冻结的旧地址
      // 会让「返回 DSH」的兜底打开一个死链接。
      dshUrl: this.currentDshUrl(),
    }

    if (!this.ready) {
      // 把指令先排进队列，再拉进程；拉起来后 onEvent('ready') 会 flush
      this.pending.push(command)
      if (this.pending.length > 8) this.pending.shift()
      await this.ensure()
      return
    }
    this.write(command)
  }

  /** 插件卸载：结束 helper 进程，释放热键与窗口。 */
  dispose() {
    this.disposed = true
    this.pending.length = 0
    this.lastKeys.clear()
    const child = this.child
    this.child = null
    this.ready = false
    if (!child) return
    try {
      // 先礼后兵：能写就发 quit，让它自己收窗口；写不进去就直接 kill
      if (child.stdin?.writable) child.stdin.write('{"cmd":"quit"}\n')
    } catch {
      // 忽略：下面还有 kill 兜底
    }
    setTimeout(() => {
      try {
        child.kill()
      } catch {
        // 已经退出就会抛，忽略
      }
    }, 800)?.unref?.()
  }
}

// ---------------------------------------------------------------------------
//  会话信息提取
// ---------------------------------------------------------------------------

/** 取会话对象（拿不到就返回 undefined，插件降级成「只弹不认名字」）。 */
function sessionOf(ctx, agentId) {
  try {
    return ctx?.get?.('sessions')?.get?.(agentId)
  } catch {
    return undefined
  }
}

/** 取会话标题；Host 侧与桌面端窗口标题同源。 */
function titleOf(ctx, session) {
  if (!session) return 'DSH'
  try {
    const snapshot = ctx?.get?.('sessionTitle')?.get?.(session)
    return oneLine(snapshot?.title, 40) || 'DSH'
  } catch {
    return 'DSH'
  }
}

/**
 * 判断这一轮是怎么结束的：正常完成还是出错/被打断。
 * 只往会话尾部找最近一次 turn/end，找不到就按「完成」处理。
 */
function turnReasonOf(session) {
  try {
    const events = session?.snapshotEvents?.() ?? []
    for (let i = events.length - 1; i >= 0; i -= 1) {
      const event = events[i]
      if (event?.type === 'turn/end') return event.data?.reason?.kind ?? 'completed'
    }
  } catch {
    // 读事件失败不影响弹卡
  }
  return 'completed'
}

/** 子代理的会话不进通知：它们结束时你并不需要立刻回到 DSH。 */
function isSubagent(session) {
  return session?.header?.origin === 'subagent'
}

// ---------------------------------------------------------------------------
//  插件主体
// ---------------------------------------------------------------------------

/** Cordis 入口：注册事件监听，按需拉起 helper。 */
export function apply(ctx) {
  /** helper 句柄；懒创建，第一次要弹卡才真正拉起进程。 */
  let helper

  /** 懒取 helper，顺带保证插件卸载后不再创建。 */
  const helperOf = () => {
    helper ??= new ToastHelper(ctx)
    return helper
  }

  // 插件卸载 / 依赖重建时收尸，避免留下孤儿 PowerShell 进程
  ctx.effect(() => () => {
    helper?.dispose()
    helper = undefined
  })

  // 预热：apply 后主动把 helper 拉起来（不等第一张卡）。
  // 原因：全局设置热键和卡片上的 ⚙ 都活在这个进程里，没有它用户就
  // 打不开设置窗口；而且预热能省掉第一张卡的 1~2 秒冷启动。
  const warmup = setTimeout(() => {
    void helperOf().ensure()
  }, 1200)
  warmup?.unref?.()

  // 心跳保活：helper 万一挂了（用户手动结束、PowerShell 崩溃），
  // 30 秒内自动补一个回来，否则「热键能开设置」这件事就又失效了。
  const keepAlive = setInterval(() => {
    void helperOf().ensure()
  }, 30000)
  keepAlive?.unref?.()

  ctx.effect(() => () => {
    clearTimeout(warmup)
    clearInterval(keepAlive)
  })

  /** 记录每个 agent 上一拍的状态，用来识别 running → idle 的跳变。 */
  const lastStatus = new Map()

  // ---- 1. 一轮跑完 ----
  ctx.on('agent/status', (payload) => {
    const agentId = payload?.agent?.id
    const status = payload?.status
    if (!agentId || !status) return

    const previous = lastStatus.get(agentId)
    lastStatus.set(agentId, status)

    // 只关心「从 running 变成 idle」，避免启动瞬间的 idle 也弹卡
    if (status !== 'idle' || previous !== 'running') return

    const session = sessionOf(ctx, agentId)
    if (isSubagent(session)) return

    const reason = turnReasonOf(session)
    const failed = reason === 'error' || reason === 'blocked'
    const title = titleOf(ctx, session)
    void helperOf().notify({
      kind: failed ? 'error' : 'done',
      title: failed ? '⚠ 这一轮没跑通' : '✅ 任务完成',
      body: failed
        ? `${title}：本轮以「${reason}」结束，回 DSH 看报错。`
        : `${title}：这一轮跑完了。点这里或「返回 DSH」切回去看结果。`,
      key: `done:${agentId}:${nowMs()}`,
    })
  })

  // ---- 2. 有选项等你选（ask_user_question） ----
  ctx.on('user-questions/request', (request, next) => {
    try {
      const first = request?.questions?.[0]
      const header = oneLine(first?.header, 30)
      const question = oneLine(first?.question, 120)
      const session = request?.agent?.id ? sessionOf(ctx, request.agent.id) : undefined
      const count = request?.questions?.length ?? 0
      void helperOf().notify({
        kind: 'ask',
        title: '❓ 等你选一下',
        body: `${header ? `${header}：` : ''}${question}${count > 1 ? `（共 ${count} 个问题）` : ''} —— 点卡片切回 DSH 作答，${titleOf(ctx, session)}。`,
        key: `ask:${request?.agent?.id ?? 'unknown'}:${oneLine(question, 40)}`,
      })
    } catch {
      // 弹卡失败绝不能阻断提问流程
    }
    // 原样往下传：本插件只负责提醒，不参与作答
    return next()
  })

  // ---- 3. 有审批等你点（工具授权） ----
  ctx.on('approval/request', (request, next) => {
    try {
      const tool = oneLine(request?.toolName, 40)
      const reason =
        oneLine(request?.displayReason?.zh ?? request?.displayReason?.en ?? request?.reason, 100)
      const session = request?.agent?.id ? sessionOf(ctx, request.agent.id) : undefined
      void helperOf().notify({
        kind: 'ask',
        title: '🔐 等你授权',
        body: `${tool ? `工具「${tool}」` : '有工具调用'}在等你放行${reason ? `：${reason}` : ''} —— 点卡片切回 DSH 处理，${titleOf(ctx, session)}。`,
        key: `approval:${request?.callId ?? request?.agent?.id ?? 'unknown'}`,
      })
    } catch {
      // 同上：不阻断审批
    }
    return next()
  })

  log(ctx, 'info', `task-alert 已加载，helper=${HELPER_SCRIPT}`)
}
