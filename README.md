# jtag_identify —— 用边界扫描在 Vivado 里识别 FPGA 型号

**纯 Tcl 驱动**：把 `jtagid.tcl` source 进 Vivado 的 Tcl Console，之后就是一组命令，
不依赖 Python、不下载 bitstream、不换 FTDI 驱动。

识别的原理是 **IEEE 1149.1 边界扫描**：
TAP 复位后读 **IDCODE** → 用 **BSDL** 文件里的 `IDCODE_REGISTER` 位型反查 → 型号 / 封装 / IRL / BSR。

---

## 1. 用法

### 在 Vivado GUI 的 Tcl Console 里

```tcl
source D:/work2026/ai/opencode/jtag_identify/jtagid.tcl
jtagid help
jtagid version
jtagid identify
```

### 批处理

```powershell
vivado -mode batch -source D:/work2026/ai/opencode/jtag_identify/jtagid.tcl -tclargs identify -package SFVC784
```

（第一条 tclarg 是子命令；只有它属于本驱动时才自动执行，所以 GUI 里 source 不会误触发。）

### 图形界面（Xilinx 官方 tk_tunnel 的原生 Tk 窗口，推荐）

在 **Vivado IDE 的 Tcl Console** 里（2018.3 实测）：

```tcl
source D:/work2026/ai/opencode/jtag_identify/jtagid_tk_gui.tcl
```

或双击 **`jtagid_tk.cmd`**（它打开 Vivado IDE 并自动 source 同一份前端；**它开出来的那个控制台
窗口就是后端，别关** —— 里面就是 Vivado 的日志和 `jtagid: console is free ...` 那几行）。
用 `set JTAGID_VIVADO=<你的 vivado.bat>` 可以指定版本（默认用 PATH 上的 `vivado.bat`）。

窗口是**真正的 Tk 窗口**，由 Xilinx 官方 TclStore 应用 `::tclapp::xilinx::tk_tunnel` 搭桥。
**前端 / 后端是分开的**：

```
  ┌─ 前端：独立的 wish 进程 ────────┐        ┌─ 后端：这个 Vivado 会话 ────────┐
  │ 真正的 Tk 窗口（jtagid_tk_ui）  │  socket│ jtagid_tk_gui.tcl 常驻          │
  │ 表格 / 过滤器 / 点选            │ ─────► │ 电缆、驱动、BSDL 索引都在这里    │
  │ 点一下就 broadcast 一条命令 ────┼────────┤ 由 Vivado 的空闲事件循环送达     │
  └────────────────────────────────┘        └────────────────────────────────┘
```

要点：

* **窗口弹出就是普通弹出**：`wm deiconify` + `raise` + 取一次键盘焦点，出现在屏幕居中位置
  （实测 `1020x740+450+113`，1920×1080；`ismapped=1`、`focus=.g`、`topmost=0`），
  之后不做任何置顶把戏，叠放跟普通窗口一样。
* **source 它不会卡住 Vivado**。实测 `source` 只花 **1.8 秒**（起 Tk 进程 + 送窗口代码 + 等窗口
  “hello”），然后立刻返回；识别、扫描等都在后台由事件循环送进来执行，控制台随即可用。
* **后端常驻**：只要 Vivado 不关，服务就一直在。点窗口的“关闭”只是 `wm withdraw`（隐藏），
  Tk 进程和后端都还在 —— 再 `jtagid gui` 就**原样**回来（同一个进程、表格里的数据还在）。
  真正停掉用 `::jtagid::tkhost::stop`（或 `jtagid gui-stop`）。
* 关掉 Vivado（或断开连接）时，Tk 端会收到 EOF 自己退出，不会留孤儿进程。
* **必须用 Vivado IDE**：实测 `vivado -mode tcl`（纯 Tcl REPL）在等待输入时**不处理** Tcl 事件，
  那种会话里窗口收不到回答，前端会在状态栏提示“Vivado 没有响应”。
  所以 `jtagid_tk.cmd` 用 `-mode gui` 起 IDE，而不是 `-mode tcl`。

| 区域 | 内容 |
|---|---|
| 主窗口 | 一行两个按钮：**识别 FPGA 型号** 和 **选择 BSDL**（关闭按钮不需要，窗口标题栏自带；链上器件表、BSDL 目录、封装提示、料号、复制路径/打开文件夹都已移除） |
| BSDL 目录 | 界面里没有这个输入：默认就是**相对路径 `./bsdl`**（工具自己的目录旁边那份，840 个文件），其次是 `<脚本目录>/bsdl`；要换用 `jtagid bsdl-dir <dir>` |
| 链上器件 | 每个 TAP 一行：器件名 / PART / IDCODE / 解码（Xilinx FPGA 会标注） |
| 选择 BSDL 弹窗 | **封装 / 型号 / 关键字三个过滤器** + 候选表（型号/封装/IRL/BSR/cells/文件）+ 详情区（die / 同 IDCODE 型号 / PS 与 PL 差异 / 判定办法）+「使用这份 BSDL」「取消」；双击一行等于直接使用 |
| 绑定 | 选中一行按「使用这份 BSDL」→ 器件（按 IDCODE）↔ BSDL 写入 `<工具目录>\.jtagid\bindings.txt`，主窗口立刻显示，弹窗关闭 |

**打开窗口什么都不会自己做**：不识别、不绑定、不弹窗，只有点「识别 FPGA 型号」之后才会读链，读完有候选就自动弹出选 BSDL 的窗口（也可以随时点主窗口的「选择 BSDL」打开）。
任何一步在后端出错，原因都会出现在状态栏并把按钮解锁（不会再出现“点了没反应”）。

**绑定是持久的、以后能直接用**：

```tcl
jtagid bsdl-for                 ;# 打印/返回这颗 FPGA 绑定的 BSDL 路径（脚本里可直接用）
jtagid bind                     ;# 列出所有绑定
jtagid bind -idcode 0x14710093 -bsdl <path>     ;# 手工绑一份
jtagid identify                 ;# 输出里会多一行  bound BSDL : ...
```

绑定文件 `<工具目录>\.jtagid\bindings.txt`（跟着工具走、不进版本库；`%LOCALAPPDATA%\jtagid_identify` 只放可丢的日志和索引缓存），一行一条、
`idcode<TAB>device<TAB>part<TAB>die<TAB>package<TAB>bsdl<TAB>when`（ASCII，可直接编辑）。
记录里存的是**解析后的绝对路径**；取用时再解析一次（当前目录 → 工具目录 → BSDL 目录 →
按文件名全树搜索），所以换工作目录、甚至把 BSDL 树搬走，绑定都还能用；
文件真的没了就在 `jtagid bind` 里标 `(MISSING)`、`bsdl-for` 报明确错误。
重开窗口或重新识别时会自动带出已有绑定，那一行在弹窗里标成「已绑定」并自动选中。

| 命令 | 作用 |
|---|---|
| `jtagid gui` | 打开窗口；已经在跑就**恢复**窗口（不重启前端） |
| `jtagid gui-status` | 端口 / Tk 进程 / 是否连着 / 窗口状态 / 空闲循环是否在服务 |
| `jtagid gui-stop` | 停前端（Vivado 会话不受影响） |
  （首行是 BSDL 目录路径，换目录会自动重建；不会写进你的 BSDL 目录）。
* 器件 ↔ BSDL 绑定：`<工具目录>\.jtagid\bindings.txt`（第一次运行会自动从旧的 `%LOCALAPPDATA%\jtagid_identify\bindings.txt` 导入一次）
| `jtagid bsdl-for ?-idcode X?` | 打印/返回绑定的 BSDL 路径（脚本可用；不带 `-idcode` 就用链上那颗 FPGA）。记录里存的是解析后的绝对路径，取用时再解析一次，换工作目录/搬树都不怕 |

| 环境变量 | 作用 |
|---|---|
| `JTAGID_VIVADO` | 仅供 `jtagid_tk.cmd`：指定用哪个 `vivado.bat`（如 2018.3），默认 PATH 上的那个 |
| `JTAGID_TKSH` | 指定用哪个 `wish.exe` 当 Tk 端。默认找 **Vivado 安装目录里自带的** `tps\win64\git-*\...\wish.exe`（本机 2018.3 → Tk 8.6.8，2024.2 → Tk 8.6.13），再找 PATH |
| `JTAGID_TK_PORT` | 隧道端口，默认 8001 |
| `JTAGID_TK_SELFTEST` | 设为 1 跑自动自检（不用手点：窗口/行数/过滤/选定的结果打到控制台与日志） |

不阻塞这件事是**实测**的，不是推断（`tests/jtagid_tk_test_nonblock.tcl`，Vivado 2018.3 IDE）：

```
jtagid: Tk window is up - backend answering (console stays free)    22:16:36
NONBLOCK|source returned after 1829 ms
NONBLOCK|script end at 22:16:36 - the prompt is free                <- 控制台已交还
jtagid: identify done: 8 candidate(s)                               22:16:54  <- 后台自己跑完
NONBLOCK|idle timer at 22:16:54 - the console loop is alive while the window is open
NONBLOCK|30s check: alive=0 win=0 idle=1                            <- 前端退出后后端仍常驻
```

为什么可行：Vivado IDE 在控制台**空闲**时仍在服务 Tcl 事件（`after` 定时器和 socket
`fileevent` 都会触发）。这一点单独测过，见 `tests/jtagid_tk_probe_idle.tcl`：

```
22:05:21 script end - console should be free now
22:05:23 AFTER_2000          <- 空闲定时器触发
22:05:49 LINE:PING1          <- socket fileevent 触发（另一进程连上来发了一行）
```

废弃的后端常驻方式（v1.0 的做法：`while {update; after 40}` 事件泵）已经去掉 —— 那种写法会让
Vivado 的主循环停摆，整个 IDE 界面都是卡的；现在只在 `::jtagid::tkhost::pump` 里保留一份
**手动**的阻塞泵，仅给“控制台不服务事件”的会话（如 `-mode tcl`）当兜底。

自检（Vivado 2018.3，`JTAGID_TK_SELFTEST=1`，约 20 秒；它自己走完 开窗 → 点识别 → 弹窗 → 过滤 → 绑定）：

```
SELFTEST|backend_resident|1      SELFTEST|idle_loop_alive|1
SELFTEST|window_exists|1         SELFTEST|ismapped|1     SELFTEST|topmost|0
SELFTEST|geometry|620x150+650+310                        （主窗口很小，居中）
SELFTEST|chooser_closed_on_open|1  SELFTEST|idle_candidates|0
                                 （开窗不动手：不识别、不弹窗、没有候选）
SELFTEST|pressing Identify FPGA
SELFTEST|chooser_mapped|1        SELFTEST|candidate_rows|8
SELFTEST|filters|全部 全部
SELFTEST|rows_after_filter|2     SELFTEST|model_choices|全部 XCZU3CG XCZU3EG
SELFTEST|rows_after_model_filter|1
SELFTEST|selected_there|D:/.../xczu3eg_sfvc784.bsd
SELFTEST|details|硅片 ZU3 // 同 IDCODE 型号 XCZU3CG XCZU3EG // 结论 同一颗硅片 … // PS 侧差异 … // PL 资源 …
SELFTEST|chooser_closed|1                                （绑定后弹窗自动关闭）
SELFTEST|binding_entry|xczu3_0 (0x14710093, ZU3) -> xczu3eg_sfvc784.bsd  D:/.../xczu3eg_sfvc784.bsd
SELFTEST|binding_stored|D:/.../xczu3eg_sfvc784.bsd       （bindings.txt 已写入）
SELFTEST|binding_idcode|0x14710093
SELFTEST|status|已绑定: xczu3_0 (0x14710093, ZU3) -> xczu3eg_sfvc784.bsd (已写入 bindings.txt)
SELFTEST|idle_loop_after_start|1
```

绑定复用也是实测的（批处理，`tests/jtagid_test_sku.tcl` 同款命令行）：

```
$ jtagid bind
# device <-> BSDL bindings (1)
  0x14710093   xczu3_0      die=ZU3    pkg=SFVC784  D:/.../xczu3eg_sfvc784.bsd
$ jtagid bsdl-for
device: xczu3_0  idcode: 0x14710093  die: ZU3  package: SFVC784
BSDL  : D:/.../xczu3eg_sfvc784.bsd          <- 返回值，脚本里可直接用
$ jtagid identify
  bound BSDL  : D:/.../xczu3eg_sfvc784.bsd
                (device xczu3_0, bound 2026-10-17 01:08:31; save it with: jtagid bsdl-for)
```

“隐藏窗口 → 后端仍在 → 原样恢复”也是实测的（`tests/jtagid_tk_test_resident.tcl`）：

```
RESIDENT|pid before hide = 30972  alive=1 win=1
jtagid: identify done: 8 candidate(s), die ZU3
RESIDENT|rows the chooser holds: 8
jtagid: window hidden - backend stays resident; run jtagid gui to re-open
RESIDENT|after Close: pid=30972 alive=1 win=0        <- 同一个 Tk 进程，没重启
RESIDENT|rows still held by the window: 8
jtagid: window restored (service was already running)
RESIDENT|after re-open: pid=30972 alive=1 win=1
RESIDENT|rows after re-open: 8                       <- 数据还在
RESIDENT|window is mapped again: 1
RESIDENT|after stop: alive=0 pid=
```

按钮点错/后端抛错也会解锁 —— `tests/jtagid_tk_test_buttons.tcl` 会把**开窗 → 识别 → 弹窗 → 过滤 → 绑定**
整条路按按钮的代码路径走一遍，最后再故意发一条不存在的命令（2018.3 实测）：

```
BTN|on-open|busy=0 chooser=0 rows=0                 <- 开窗什么都没做
BTN|pressing IDENTIFY (button path, not the self test)
jtagid: identify done: 8 candidate(s), die ZU3
BTN|after-identify|busy=0 chooser=1 rows=8          <- 弹窗自己开了，候选 8 行
BTN|filtering: package SFVC784
BTN|after-filter|busy=0 chooser=1 rows=2            <- 封装过滤真的生效
BTN|filtering: model XCZU3EG
BTN|after-model|busy=0 chooser=1 rows=1             <- 型号过滤能把兄弟 SKU 分开
jtagid: bound: 0x14710093 (xczu3_0) <- bsdl/xilinx/zynquplus/public/bsdl/xczu3eg_sfvc784.bsd  (bindings.txt)
BTN|after-use|busy=0 chooser=0 rows=1               <- 绑定后弹窗自动关闭
BTN|bound=bsdl/xilinx/zynquplus/public/bsdl/xczu3eg_sfvc784.bsd
BTN|after-bogus|busy=0 chooser=0 rows=1
BTN|after-bogus|status=失败: invalid command name "::jtagid::tkhost::cmd_this_does_not_exist"
```

> **Tcl/Tk 运行时从哪来**：Vivado 的 Tcl **本身没有 Tk**（GUI 模式实测 2018.3 / 2024.2 都是
> `package require Tk` 失败、`toplevel`/`wm`/`ttk` 全不存在；2024.2 只带了 Tk 脚本库、缺 DLL），
> 而本机所有 `wish.exe` 都是 Git for Windows 的构建 —— **包括 Vivado / Vitis_HLS 安装目录里那几个**
> （`tps\win64\git-*\...`，是 Xilinx 随 Vivado 一起发行的）。所以默认就用 **Vivado 自带的那份**
> Tk 8.6；要换成别的 Tcl/Tk（ActiveTcl、tcl.tk 8.6…）设 `JTAGID_TKSH` 即可。
>
> 另外，`tk_tunnel` 官方的 `server/start.tcl` 硬性要求 **Tcl 8.5**（8.6 直接报错），所以这里换成自己的
> `jtagid_tk_server.tcl` 作启动脚本（不做版本检查、自己起 socket 监听），并用 `jtagid_tk_wish.cmd`
> 包装启动 —— 否则 Tcl `exec` 的管道会被孙进程继承，`launch_server` 会一直卡住。

## 2. 子命令

| 命令 | 作用 |
|---|---|
| `jtagid help` | 帮助 |
| `jtagid version` | Vivado/Tcl 版本 + 硬件命令兼容性探测（`load_features labtools`、`open_hw_manager`/旧版 `open_hw`、`hw_server` 路径、已连服务版本） |
| `jtagid status` | 当前连接 / BSDL 目录 / 索引缓存 / 自起服务状态 |
| `jtagid open ?-url tcp::3121? ?-own-server 0\|1?` | 打开硬件管理器并连接 hw_server（自动兼容版本） |
| `jtagid scan ?-refresh?` | 扫描链，列出每个 TAP：器件名 / PART / IDCODE / 解码 |
| `jtagid identify ?-package SFVC784? ?-part xazu3eg-sfvc784-1-i?` | **识别型号**：IDCODE → BSDL 反查 → 型号/封装/IRL/BSR，并与 Vivado 的 PART 交叉验证。`-package` 现在**真的会过滤候选**；`-part` 按等级字母归一化匹配（`xazu3eg→XCZU3EG`）并给出推荐的那份 BSDL；同一 IDCODE 的多个型号会列出 die、PS/PL 差异和最终判定办法 |
| `jtagid close ?-shutdown-own?` | 断开；`-shutdown-own` 结束"本会话启动的" hw_server |
| `jtagid bsdl-dir ?目录?` | 查看/设置 BSDL 目录（默认 **`./bsdl`** 相对路径，其次 `<脚本目录>/bsdl`；不猜别的位置） |
| `jtagid bsdl-index ?-rebuild?` | 建立/刷新 BSDL 索引（840 个文件约 0.3~1 秒，落盘缓存，第二次瞬时） |
| `jtagid bsdl-match 0x14710093` | 只用 IDCODE 反查 BSDL，**不碰硬件** |
| `jtagid report ?-bsdl-dir D? ?-part P? ?-package P?` | 机器可读输出（制表符分隔，ASCII）：`INFO/DEV/CAND/PART/ERR`；`CAND` 每行是**一个文件自己的型号**并带 `siblings`（同 IDCODE 的兄弟型号）与 `recommended`（`-part` 命中），另有 `SKU / SKU-PS / SKU-PL / SKU-HOW` 行解释同硅片型号怎么区分 |
| `jtagid gui` | 打开 tk_tunnel 的 Tk 窗口（前端）；已在跑则恢复窗口 |
| `jtagid gui-status` | 前端/后端服务状态（端口、Tk 进程、是否连着、窗口、空闲循环） |
| `jtagid gui-stop` | 停掉 Tk 前端（Vivado 会话不受影响） |

## 3. 实测输出（本板，Vivado 2024.2）

```
jtagid loaded: Vivado 2024.2 / Tcl 8.6.13, hardware commands available, BSDL dir .../bsdl
target: localhost:3121/xilinx_tcf/Digilent/210512180081
#  device     PART     IDCODE      decoded
1  xczu3_0    xczu3    0x14710093  family=35 array=272 mfg=0x049 (Xilinx)
2  arm_dap_1  arm_dap  0x5BA00477  family=93 array=0 mfg=0x23B (ARM)

BSDL lookup: 840 files
  0x14710093 -> 8 file(s), 1 package group(s)
    * XCZU3CG/XCZU3EG  package SFVC784  IRL=12 BSR=1577 cells=1577
        .../xczu3cg_sfvc784.bsd
        .../xczu3eg_sfvc784.bsd
  your PART: xazu3eg-sfvc784-1-i -> grade letter differs: xazu3eg corresponds to XCZU3EG
conclusion:
  Vivado PART : xczu3
                (family level only: an unconfigured device yields no full PART)
  model       : XCZU3CG/XCZU3EG  package SFVC784  (IRL=12, BSR=1577)
  BSDL        : .../xczu3cg_sfvc784.bsd
stopped the hw_server that this session launched (port 3121, pid 29144)
```

要点：

* **IDCODE 无法区分 XCZU3CG / XCZU3EG**（同一硅片、BSR 指纹相同），所以两个都列出；
  具体型号看板卡/原理图，或用 `-part` 传入料号做校验。
* **车规料号 xazu3eg 对应商用 XCZU3EG**（只差第 2 个等级字母）；BSDL 树里只有
  `xazu3teg_sfvc784.bsd`（XAZU3TEG，IDCODE `0x04AF2093`、BSR=1227），**与本板硅片不符**，
  反查不会命中 —— 以硅片 IDCODE 为准。
* 未配置器件时 Vivado 的 `PART` 只到家族级（`xczu3`），完整 PART 要等器件配置后才读得到。

### 为什么 XCZU3CG / XCZU3EG 区分不了 —— 以及到底怎么最终确定

结论先说：**这两个型号是同一颗硅片，JTAG/边界扫描在物理上就分不开**，不是驱动没做。
本机实测（Vivado 2018.3）两条独立证据：

| 证据 | 实测结果 |
|---|---|
| 两份 BSDL 逐字节比对 | `xczu3cg_sfvc784.bsd` 与 `xczu3eg_sfvc784.bsd` 都是 118210 字节 / 2997 行，只有 44 行不同，而且**全是型号名替换**；把 `XCZU3CG`、`XCZU3EG` 都替换成 `MODEL` 后 **SHA-256 完全相同** → IDCODE、IRL、BSR、指令码、引脚表、边界寄存器全都一致 |
| Vivado 自己的器件库 | `xczu3cg-sfvc784-1-e` 与 `xczu3eg-sfvc784-1-e` 的属性**除 `DEVICE`/名字外逐项相同**：8820 slices、70560 LUT、141120 FF、360 DSP、216 BRAM、252 IOB、3 MMCM、0 GT、同一封装/同一温度范围 |
| 硬件侧 | 未配置时 Vivado 只报家族级 `PART=xczu3`；IDCODE 只编码到 die（family=35 array=272）这一级 |

所以差别只在 **PS**：`CG` 没有 GPU/VCU，`EG` 带 Mali-400 GPU（`EV` 再加 VCU）——这是出厂测试分档的结果，
硅片里没有任何可读字段记录它（IDCODE 与配置寄存器都只到 die 一级）。

**驱动现在会把这件事讲清楚**，而不是含糊地写 "XCZU3CG/XCZU3EG"（`jtagid identify` 实测输出）：

```
  die          : ZU3    (from IDCODE 0x14710093; the die is what boundary scan proves)
  same IDCODE  : XCZU3CG XCZU3EG  (2 model(s))
    PS         : XCZU3CG    CG: no GPU, no VCU
    PS         : XCZU3EG    EG: Mali-400 GPU (no VCU)
    PL         : XCZU3CG    slices=8820 LUT=70560 DSP=360 BRAM=216 MMCM=3
    PL         : XCZU3EG    slices=8820 LUT=70560 DSP=360 BRAM=216 MMCM=3
  verdict      : these are the SAME die. ... boundary scan cannot tell them apart
```

**最终确定 SKU 的四条路（按可靠度排序）** —— 窗口详情区里也写着这四条：

1. **看芯片丝印**（最直接）：丝印就是完整订货号，例如 `XCZU3EG-1SFVC784I`，型号/速度/温度/封装一次全有。
2. **看板卡 BOM / 原理图 / 丝印**：汽车级 `XAZU…`、军工 `XQZU…` 与商用 `XCZU…` 是同一颗硅片，只差等级字母
   （驱动会做等级归一化：`xazu3eg-sfvc784-1-i` → `XCZU3EG`）。
3. **PS 侧跑着 Linux 时**：有 Mali GPU 才是 EG/EV —— `ls /proc/device-tree | grep -i gpu`（会看到 `gpu@fd4b0000`）、
   `dmesg | grep -i mali`、`ls /sys/bus/platform/drivers/mali`；全都没有 → CG。
4. **把已知信息喂给驱动**：`jtagid identify -package SFVC784 -part xazu3eg-sfvc784-1-i`
   —— 封装过滤 + 料号匹配，命中的那一行在窗口里高亮成「推荐」，CLI 直接给出推荐的 BSDL 路径。

**界面里的过滤器现在真的能筛**（2018.3 实测，`JTAGID_TK_SELFTEST=1`）：

| 过滤器 | 实测效果 |
|---|---|
| 封装 | `SFVC784`：候选从 8 个缩到 **2** 个（`candidate_rows=2`） |
| 型号 | 下拉里是**每个文件自己的型号**（`XCZU3CG`、`XCZU3EG`，不再是合并的 `XCZU3CG/XCZU3EG`）→ 再选 `XCZU3EG` 只剩 **1** 行（`rows_after_model_filter=1`） |
| 关键字 | 匹配 路径 / 实体名 / 型号 / 封装 |

封装/型号就用弹窗里那两个下拉框筛（界面不再有“封装提示/料号”输入框）；
已经在弹窗里绑定的那一行会标成「已绑定」并自动选中。

## 4. 版本自动兼容（按能力探测，不写死版本号）

| 版本差异 | 处理 |
|---|---|
| 硬件命令需 `load_features labtools` | 自动加载；失败记录原因 |
| `open_hw_manager` vs 旧版 `open_hw` | 优先新命令，缺失退回旧命令 |
| 必须先初始化 labtools 系统（否则 `[Labtoolstcl 44-235]`） | 所有硬件动作前**无条件**先 `open_hw_manager` 一次。注意：`get_hw_targets`/`get_hw_servers` 在未初始化时**只 warning 不报错**，不能用来探测状态 |
| `connect_hw_server` 参数集随版本变 | 先试 `-allow_non_jtag`，失败退回不带该开关 |
| 客户端连不上更老的 hw_server（`[Labtools 27-3366] Cannot support older hw_server version`） | 自动用**同版本** `hw_server` 在空闲端口自起（优先 3121，被占则递增） |
| **Tcl 8.5（Vivado 2018.3）/ 8.6（2020+）差异** | 不用 `format %b`、不用 `expr 0b...`（8.6 才有），二进制转换自己实现 —— 实测 2018.3 的 Tcl 8.5.14 与 2024.2 的 8.6.13 都能跑 |
| 设备没有某个属性（如 `arm_dap` 没有 `USERCODE`） | 先 `list_property` 判断存在性再读，避免 Vivado 打印 `[Labtoolstcl 44-56] ... does not have a [X] property` |
| 会话结束 | 批处理退出前 `close -shutdown-own`：只回收"本会话启动/由 Vivado 代启"的 hw_server，不动你原有的服务 |

**实测可用版本**：Vivado **2018.3**（Tcl 8.5.14，GUI 与批处理都行）与 **2024.2**（Tcl 8.6.13），
两条链路的输出一致：`0x14710093 → XCZU3CG/XCZU3EG, package SFVC784, IRL=12, BSR=1577`。

## 5. 写 Tcl 驱动踩过的坑（都已修，代码里有注释）

1. **脚本必须纯 ASCII**。Vivado 的 Tcl `source` 用系统代码页（本机 cp936）解码脚本，
   UTF-8 中文会被拆错，偶尔凑出 `{`/`}`/`"` 直接报 `missing close-brace`；
   加 UTF-8 BOM 更糟（Tcl 把 BOM 当成命令的一部分）。
2. **Tcl 的 regexp 是 leftmost-longest**：`(.*?);` 非贪婪**仍选最长整体匹配**，
   会越过真正的 `;` 吃到下一个属性的分号（症状：IDCODE 模式串变成 70 位）。
   取属性体要用确定性的 `([^;]*);`。
3. **模式以 `-` 开头会被当成选项**：`regsub -all {--[^\n]*} ...` 要写成
   `regsub -all -- {--[^\n]*} ...`。
4. **`exec` 会为子进程建管道并等待**：`exec cmd /c start ...` 启动 hw_server 会
   **永久阻塞**（子进程继承管道），连 Vivado 一起被拖死。改用
   `exec powershell -Command Start-Process ... -PassThru`（顺带拿 PID 便于回收），
   或至少把 stdout/stderr 重定向到 `NUL`。
5. **`switch` 按字符串比较**：`switch -- $mfg {0x049 {...}}` 对整数 73 永不匹配，
   要 `format %03X` 后再比。
6. **`array set opts $args` 不支持裸开关**（`-refresh`/`-shutdown-own`），
   驱动内用自带 `parse_opts` 同时支持 `-k v` 与 `-k`。
7. **Tcl 8.5 没有 `%b`**：`format %032b` 在 Vivado 2018.3 报
   `bad field specifier "b"`（`expr 0b...` 同理不可用），二进制/整数转换要自己写
   （`int_to_bits` / `bits_to_int`）。
8. **读设备不存在的属性会打 ERROR**：`get_property USERCODE` 对 `arm_dap` 这类
   只读 TAP 不适用，即使 `catch` 接住，Vivado 仍会打印
   `[Labtoolstcl 44-56] hw_device [x] does not have a [USERCODE] property`；
   要先用 `list_property` 判断。
9. **`catch {脚本} 变量` 里那个变量是“结果”，不是“错误”**。写成
   `catch {::jtagid::connect} err; if {$err ne ""} {...}` 会把**成功返回值**
   （connect 返回 URL、bsdl_index 返回文件数 840）当成错误报出来 —— 必须判
   `catch` 的**返回码**：`if {[catch {脚本} out]} {...}`。这个坑在 GUI 里表现为
   `ERROR: localhost:3121` / `ERROR: 840`。
10. **GUI 相关的 API 名字要用对**：`create_gui_custom_command` /
    `create_gui_custom_command_arg` / `get_gui_custom_command_args -command_name X` /
    `remove_gui_custom_commands`（**没有** `delete_gui_custom_command`），
    用 `-help` 就能在**批处理**里查到（不必开 GUI；反过来，GUI 模式下
    `-source` 的脚本偶发被 IDE 初始化挡在后面，不适合做自动化验证）。
11. **“不卡死”靠的是 Vivado 自己**：IDE 模式实测控制台**空闲**时 `after` 定时器与 socket
    `fileevent` 都会触发（`tests/jtagid_tk_probe_idle.tcl`），所以前端可以 source 完就返回；
    但 `vivado -mode tcl` 的 REPL 在等输入时**不处理事件**（同一脚本在里面一个标记都不出），
    批处理模式则会在脚本结束后直接退出 —— 这就是 GUI 必须走 IDE 的原因。
    不要再用 v1.0 那种 `while {update; after 40}` 常驻泵：Tcl 的 `update` 不跑 Vivado 的
    Qt 主循环，IDE 会整片卡住。
12. **长命令执行期间事件仍会被处理**：驱动里 `open_hw_target`/识别这类调用内部会让 Vivado
    泵事件，于是新的按钮点击可能**嵌套**进来。后端用 `S(running)` 标志判断，忙时把命令
    `after 50` 重新排队（实测：识别进行中点的“关闭”，是在识别结束后才执行的）。
13. **非阻塞 socket 上的 `flush` 不能当错误**：为了能安全 `gets`（避免半行阻塞），隧道 socket
    设成 `-blocking 0`；写不进去时 Tcl 会先缓冲、之后由写事件发出去，所以 `flush` 的
    EAGAIN 要 `catch` 掉，不能当成发送失败（否则大块数据如整份窗口代码会被误判丢弃）。
14. **source 期间不能让长活在跑**：前端窗口建好后先发一条 “hello”，后端收到才回
    “backend_ready”，自动识别由它触发 —— 这样 source 的返回时间永远是零点几秒，
    不会把一次 6~20 秒的识别算进启动里。
15. **`lappend` 和 `dict lappend` 不能混用**：`res` 是 dict 的时候写
    `lappend res devices $d`，Tcl 会把它当**列表**追加，得到一个**元素个数为奇数**的畸形
    dict；读回来时 `dict get $d name` 直接抛 `missing value to go with key`。
    这就是「扫描链点了没反应」的根因：`collect_report` 里设备列表被写坏 → 前端 `data_from`
    抛错 → 窗口收不到回复、按钮一直灰着（看起来就是卡死）。已改为 `dict lappend`
    （`jtagid.tcl` 里有注释，别改回去）。
16. **设备记录的字段要和渲染代码对齐**：`::jtagid::devices` 只给 `name/part/idcode`，
    而窗口要读 `mfg/family/array/fpga` —— 缺键时 `dict get` 抛错、重绘中断、
    `set_busy 0` 执行不到，窗口就永久停在“忙”（按钮全灰）= 用户眼里的卡死。
    现在设备记录统一由 `::jtagid::device_records` 产出（`collect_report` 与扫描共用一份），
    候选记录由前端 `norm_cand` 补齐字段，`render` 全程用 `dget` 取键。
17. **任何后端错误都必须回一条消息**：`run_line` 里命令抛错时会回
    `::jtagid::tkgui::show_error "..."`（并记下 `errorInfo` 前 400 字），前端也会 `set_busy 0`
    —— 窗口因此永远能解锁并显示原因，不会再“卡死没有反应”。另外
    `catch {set x [f]} err` **成功时 `err` 是结果**：`cmd_reindex` 曾经把 840（文件数）
    当成错误显示成红色“失败”。
18. **`split` 的第二个参数是“字符集合”，不是分隔符**：驱动用 `" | "` 把多行拼成一条
    （`a | b`），前端却写 `split $text { | }` → 空格和竖线都当分隔符，
    `"CG: no GPU, no VCU"` 被切成一堆单词。要按**单个**分隔符切就写 `split $text |`
    （这和第 2 条的 regexp 贪婪是同一种“把分隔/匹配规则想当然”的坑）。
19. **`get_parts` 没匹配到会打 WARNING，`catch` 拦不住**：查器件库时先拼对通配符，
    封装未知就别拼出 `xczu3cg--*`（用 `xczu3cg-*`），并且用 `get_parts -quiet`，
    否则每次识别都会冒出 `[Coretcl 2-179] No part matched ...`。
20. **报告里可能压根没有 `info`**（同一条线上有两个 IDE 抢电缆、hw_server 没起来时）：
    后端的回包代码里写 `dict get [dict get $res info] die` 就会抛
    `key "die" not known in dictionary`（2022.2 上实测到），把真正的错误盖掉。
    这类取值一律走 `::jtagid::dget`，并且有 errors 时把 errors 报到窗口。
21. **相对路径的 BSDL 不能假设工作目录相同**：`./bsdl` 是相对路径，窗口在
    “Vivado 从别的目录启动”的会话里绑定过一份相对路径，回到另一个会话
    （工作目录不同）就成了 `no such BSDL file`。所以
    `::jtagid::resolve_bsdl` 会按 “当前目录 → 工具目录 → BSDL 目录 → 文件名全树搜索”
    依次解析，绑定记录存在 `<工具目录>\.jtagid\bindings.txt`（跟工具走，不放 `%LOCALAPPDATA%`——那里只放可丢的日志和索引），存**解析后的绝对路径**，用的时候再解析一次
    （树被搬走也还能按文件名找回来）；`jtagid bind` 对找不到的项标 `(MISSING)`。
    同理 `<script dir>` 是用 `[info script]` 在 **source 时**记进 `state(here)` 的，
    运行期在 proc 里 `[info script]` 是空的，不能依赖它。

## 6. 文件与缓存

| 文件 | 说明 |
|---|---|
| `jtagid.tcl` | 全部实现（约 1200 行，纯 ASCII，无 Python 依赖） |
| `jtagid_tk_gui.tcl` | **后端（常驻服务）**：在 Vivado 里跑，经 tk_tunnel 驱动 Tk 窗口；source 完立刻返回控制台 |
| `jtagid_tk_ui.tcl` | **前端窗口本体**（Tk 控件、过滤器、点选），被送到 Tk 进程里执行 |
| `jtagid_tk_server.tcl` | Tk 端启动脚本（绕开官方脚本的 Tcl 8.5 限制；Vivado 一断开就自己退出） |
| `jtagid_tk_wish.cmd` | Tk 进程启动包装（避免 exec 管道继承卡死） |
| `jtagid_tk.cmd` | 双击启动器：开 Vivado IDE 并自动 source 前端（**那个控制台窗口就是后端，别关**） |
| `tests/jtagid_tk_probe_idle.tcl` | 诊断：测当前会话空闲时是否服务 Tcl 事件（“不卡死”的前提） |
| `tests/jtagid_tk_test_nonblock.tcl` | 验证：source 立即返回、控制台空闲仍在服务、识别在后台跑完 |
| `tests/jtagid_tk_test_resident.tcl` | 验证：关窗=隐藏、`jtagid gui` 原样恢复、`stop` 后 Vivado 无恙 |
| `tests/jtagid_tk_test_buttons.tcl` | 验证：识别→弹窗→过滤→绑定 全自动走一遍，坏命令也会报错+解锁 |
| `tests/jtagid_test_sku.tcl` | 验证：同 IDCODE 型号的 die/PS/PL 分析与推荐选取（批处理即可跑，需要线缆） |
| `tests/check_syntax.tcl` | 开发用：`tclsh tests/check_syntax.tcl *.tcl` 只编译不执行地做语法检查 |
| `jtagid_gui_msgs.txt` | 界面文案（UTF-8，`key<TAB>文本`；只含 tk_tunnel 窗口用到的键，缺失就走代码里的英文默认值） |
| `bsdl/` | BSDL 树就放这里（默认的相对路径 `./bsdl`，本仓库里是 840 个 Xilinx 官方文件；`.gitignore` 已忽略它） |
| .jtagid/ | 器件 ↔ BSDL 绑定（indings.txt，跑起来才会生成；.gitignore 已忽略） |

* BSDL 索引缓存：`%LOCALAPPDATA%\jtag_identify\bsdl_index_tcl.txt`
  （首行是 BSDL 目录路径，换目录会自动重建；不会写进你的 BSDL 目录）。
* 器件 ↔ BSDL 绑定：`<工具目录>\.jtagid\bindings.txt`（第一次运行会自动从旧的 `%LOCALAPPDATA%\jtagid_identify\bindings.txt` 导入一次）
  （GUI 里按「使用这份 BSDL」时写入；`jtagid bsdl-for` 读它；可直接编辑）。
* 性能：840 个文件建索引 0.3~1 秒；之后命中缓存瞬时。
