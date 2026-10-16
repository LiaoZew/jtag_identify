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

### 图形界面（推荐）

双击 **`jtagid_gui.cmd`**：它会另起一个 Vivado Tcl 进程做后端，然后用浏览器打开界面。
不用 Tk，也不用装任何外部 Tcl/Tk。

界面里有：

| 区域 | 内容 |
|---|---|
| 工具栏 | **识别 FPGA 型号** 按钮、BSDL 目录、封装提示、料号校验、重建索引、关闭服务 |
| 链上器件 | 每个 TAP 一行：器件名 / PART / IDCODE / 解码（Xilinx FPGA 会标绿） |
| BSDL 候选 | **封装 / 型号 / 关键字三个过滤器** + 表格（型号 / 封装 / IRL / BSR / cells / 文件），**点一行即选定** |
| 已选定 | 完整路径 + **复制路径** + **打开所在文件夹** + entity/IRL/BSR 详情 |

打开页面会自动先识别一次；选定结果写入 `%LOCALAPPDATA%\jtag_identify\selected_bsdl.txt`。

也可以不通过 `.cmd` 启动：

```tcl
source D:/work2026/ai/opencode/jtag_identify/jtagid_web_gui.tcl     ;# 在当前 Vivado 里起服务
```

```powershell
set JTAGID_PORT=8760          # 可选，默认 8760（被占则 8761/8762/8763）
set JTAGID_NO_BROWSER=1       # 可选，不自动开浏览器
```

> **为什么界面是网页而不是 Tk 窗口**：Vivado 的 Tcl **没有 Tk 运行时**。实测（GUI 模式）
> 2018.3（Tcl 8.5.14）与 2024.2（Tcl 8.6.13）都是 `package require Tk` →
> `can't find package Tk`，且 `toplevel` / `wm` / `ttk::button` **一个都不存在**；
> 2024.2 只带了 Tk 的**脚本库**（`tps\tk\tk8.6`），缺 `tk86t.dll`，加进 `auto_path`
> 后会报 `couldn't load library libtk8.6.so`。本机能找到的所有 `wish/tclsh`
> （包括 Vivado / Vitis_HLS 树里的 `tps\win64\git-*\...`）**都是 Git for Windows 的**。
> 所以界面用「Tcl 起 HTTP 服务 + 浏览器渲染」实现：**零外部依赖、按钮/表格/过滤器全都有**，
> 逻辑仍然 100% 在 Tcl 里（`jtagid_web_gui.tcl`），页面只是显示层（`jtagid_web_gui.html`，UTF-8）。
> 如果你想要真正的原生窗口，两条路：① 装一个非 Git 的 Tcl/Tk（如 tcl.tk 的 8.6 / ActiveTcl），
> 然后跑 `jtagid_gui.tcl`（独立的 Tk 窗口 + 常驻后端，已验证握手 6.5 秒）；
> ② 用 Xilinx 官方 TclStore 里的 **`tk_tunnel`**（外部 Tcl/Tk + socket 隧道，同样需要外部运行时）。

### 附：Vivado 原生菜单/对话框（可选，轻量）

```tcl
source D:/work2026/ai/opencode/jtag_identify/jtagid.tcl
source D:/work2026/ai/opencode/jtag_identify/jtagid_vivado_gui.tcl
```

菜单 **Tools → Custom Commands** 会出现三个**固定**命令（不会因为扫描结果而新增/变化）：

| 菜单项 | 说明 |
|---|---|
| `jtagid: 识别 FPGA 型号` | 对话框：BSDL 目录 / 封装提示 / 料号校验 → 识别结果打印到 Tcl Console |
| `jtagid: 扫描 JTAG 链` | 只列链上所有 TAP |
| `jtagid: 环境与版本` | Vivado/Tcl 版本、硬件命令兼容性、Tk 是否可用 |

（这套 API 的参数只有文本框：选项仅 `-default` / `-comment` / `-optional`，没有 `-arg_type`
/ `-choice_list`，所以"过滤选择"放在上面的图形界面里做，这里只做识别。）

## 2. 子命令

| 命令 | 作用 |
|---|---|
| `jtagid help` | 帮助 |
| `jtagid version` | Vivado/Tcl 版本 + 硬件命令兼容性探测（`load_features labtools`、`open_hw_manager`/旧版 `open_hw`、`hw_server` 路径、已连服务版本） |
| `jtagid status` | 当前连接 / BSDL 目录 / 索引缓存 / 自起服务状态 |
| `jtagid open ?-url tcp::3121? ?-own-server 0\|1?` | 打开硬件管理器并连接 hw_server（自动兼容版本） |
| `jtagid scan ?-refresh?` | 扫描链，列出每个 TAP：器件名 / PART / IDCODE / 解码 |
| `jtagid identify ?-package SFVC784? ?-part xazu3eg-sfvc784-1-i?` | **识别型号**：IDCODE → BSDL 反查 → 型号/封装/IRL/BSR，并与 Vivado 的 PART 交叉验证 |
| `jtagid close ?-shutdown-own?` | 断开；`-shutdown-own` 结束"本会话启动的" hw_server |
| `jtagid bsdl-dir ?目录?` | 查看/设置 BSDL 目录（默认自动找 `./bsdl`，再找 `../vivado_tools/bsdl`） |
| `jtagid bsdl-index ?-rebuild?` | 建立/刷新 BSDL 索引（840 个文件约 0.3~1 秒，落盘缓存，第二次瞬时） |
| `jtagid bsdl-match 0x14710093` | 只用 IDCODE 反查 BSDL，**不碰硬件** |
| `jtagid report ?-bsdl-dir D? ?-part P?` | 机器可读输出（制表符分隔，ASCII）：`INFO/DEV/CAND/PART/ERR` 行，供脚本与 GUI 使用 |
| `jtagid gui` | 打开 `jtagid_vivado_gui.tcl`（需要当前解释器有 `create_gui_custom_command`） |

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

## 6. 文件与缓存

| 文件 | 说明 |
|---|---|
| `jtagid.tcl` | 全部实现（约 1200 行，纯 ASCII，无 Python 依赖） |
| `jtagid_gui.cmd` | **图形界面启动器**（起后端 + 开浏览器） |
| `jtagid_web_gui.tcl` | 界面的后端：Tcl HTTP 服务 + JSON API（纯 ASCII、无外部依赖） |
| `jtagid_web_gui.html` | 界面本体（UTF-8，可直接改样式/文案） |
| `jtagid_vivado_gui.tcl` | 可选：Vivado 原生菜单/对话框（只做识别，不动态建命令） |
| `jtagid_gui_msgs.txt` | 原生菜单用到的文案（UTF-8，`key<TAB>文本`） |
| `jtagid_gui.tcl` | 可选：原生 Tk 窗口 + 常驻 `vivado -mode tcl` 后端；**需要你自己装一个非 Git 的 Tcl/Tk** |
| `bsdl/`（可选） | 放自己的 BSDL 树；缺省用 `../vivado_tools/bsdl`（840 个 Xilinx 官方 BSDL） |

* BSDL 索引缓存：`%LOCALAPPDATA%\jtag_identify\bsdl_index_tcl.txt`
  （首行是 BSDL 目录路径，换目录会自动重建；不会写进你的 BSDL 目录）。
* 性能：840 个文件建索引 0.3~1 秒；之后命中缓存瞬时。
