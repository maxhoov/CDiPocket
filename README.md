# CDiPocket

将本地 `../CDi_MiSTer` 的 Philips CD-i Mono I 基础硬件移植到 Analogue Pocket openFPGA，使用 `../core-template-1.3.0` 的 APF 框架与 Pocket 引脚配置。

这是 **0.1.0 工程验证版**。提供 HDL、Quartus 工程、原生 CUE/BIN 读取、仿真和可安装包。用户已确认此前版本可进入游戏；0.2.5-dev 加入加载黑屏后收到持续黑屏反馈，本版补上 `CDI/2352` CUE 轨道支持并修正显示就绪条件，仍需实机复测。

加载资源和 BIOS 初始化显示期间持续输出完整黑帧。图像平面或独立光标启用、且连续两帧几何一致后，在帧边界切入 CD-i 画面；不再要求原渲染器未使用的 DCR1.DE 位。保留菜单暂停：打开菜单后在垂直消隐、内存传输完成时冻结机器及光盘缓存并静音；关闭后继续。APF 文件操作、SDRAM 刷新和 NVRAM 保存继续运行。见 [启动修复记录](docs/boot-fix.md)。

## 首版范围

保留 SCC68070 / TG68K、MCD212、CDIC、68HC05 Slave MCU、伺服控制、CDDA / XA ADPCM 基础音频、CD-ROM、MK48T08B 的 8 KiB NVRAM / RTC，以及标准方向键与两键控制器。

不编译 VMPEG、Digital Video Cartridge、MPEG-1 解码器、CHD、鼠标 / 光枪、CPU Turbo、MiSTer HPS / DDR3 / OSD、自动播放内核注入或其他 MiSTer 平台扩展。系统使用约 30 MHz 的原始时钟目标。

## 安装与运行

1. 将 `dist/maxhoov.CDi_0.1.0_2026-10-04.zip` 解压到 Pocket 的 SD 卡根目录。也可复制 `dist/sdcard/` 中的文件。
2. 自行准备系统 BIOS `cdi200.rom`（524288 字节）及 Slave 2.0 固件，后者重命名为 `slave.rom`（8192 字节）。放到 `Assets/cdi/common/`。工程不附带固件或软件镜像。
3. 将原始 `.cue` 和它引用的全部 `.bin` 文件放到 `Assets/cdi/common/` 或其子目录，保留 CUE 中的文件名和相对目录。例如 `Assets/cdi/common/Example/Example.cue` 与 `Example.bin`。无需转换、合并 BIN 或创建实例 JSON。
4. 启动核心时选择 `.cue` 文件，在 CD-i 系统界面选择播放。多个 BIN 会按 CUE 自动打开，镜像文件只读。

核心作者为 `maxhoov`，安装目录为 `Cores/maxhoov.CDi/`。平台图片使用工程根目录的 `cdi.bin`，打包到 `Platforms/_images/cdi.bin`。从此前版本升级时，移除旧的 `Cores/CDiPocket.CDi/`，避免显示两个核心。

原工程验证过的固件 MD5：系统 BIOS `2969341396aa61e0143dc2351aaa6ef6`；Slave 固件 `3d20cf7550f1b723158b42a1fd5bac62`。

Pocket 的 A 对应 CD-i 按钮 1（•），B 对应按钮 2（••），X 同时按下两键。方向键移动指针。Dock 的第一个标准手柄也可使用方向键和这些面板按键；首版不接入模拟摇杆或第二个控制器。

按 Menu Button 打开 Pocket 菜单会暂停游戏及声音，关闭菜单后恢复。暂停等待下一个垂直消隐和当前内存访问完成；暂停不重置 CPU、Slave、CDIC、视频或音轨位置。菜单内的核心重置仍正常工作。

PAL 为默认值。更改 `Video region (reset)` 后使用 Pocket 的核心重置功能。支持 MCD212 的 PAL / NTSC、720 / 768 像素宽度与隔行场标记；不同显示模式的实际呈现仍需上机检查。

当前 NVRAM 槽配置使用 `Saves/cdi/common/nvram.sav`，OS 2.7 的启动日志也确认此路径；不同光盘共享该文件。内容是兼容原工程格式的 8192 字节数据。进入 Pocket 菜单时会请求保存脏数据，退出核心时由 APF 的非易失数据槽保存。读出保存期间暂停 CPU 对 NVRAM 的访问，保证快照一致；实际 SD 卡保存/恢复仍需实机验收。

## 光盘格式与限制

核心直接接受 BINARY 文件的 `MODE1/2352`、`MODE2/2352`、`CDI/2352` 和 `AUDIO`，支持单 BIN / 多 BIN、最多 99 个连续编号轨道、最多 99 个不同 BIN、`INDEX 00/01`、`PREGAP`、`FLAGS PRE/DCP/4CH`，以及常见原始数据扇区去扰码。支持带空格或 UTF-8 文件名、CRLF、UTF-8 BOM、大小写不敏感的 CUE 指令及常见描述性元数据。

`CDI/2352` 是 CUE 中的 CD-i Mode 2 原始轨道类型，与 DiscJuggler 的 `.cdi` 镜像文件是不同概念；本版不增加 `.cdi` 文件支持。

小型 RV32I 文件管理程序内嵌在 FPGA 中，启动时解析 CUE 并核对 BIN 长度。运行时按需从 SD 卡读取 2352 字节扇区，实时补全 TOC、Q 子通道及 CRC，再交给原 CDIC 缓存。合成间隙与末尾 128 扇区 lead-out 也在运行时生成。不会创建中间光盘文件，不会把整张光盘放进内存，SCC68070 仍是 CD-i 的系统 CPU。

CUE 最大 32 KiB；完整路径必须小于 256 字节，位于本平台的 Assets 目录内。BIN 长度必须是 2352 的整数倍，盘面含 lead-out 的绝对地址必须小于 100 分钟。首轨 `INDEX 01` 对应绝对 MSF 00:02:00；首轨自带间隙超过 150 扇区时会拒绝加载。缺文件、截断 BIN、非法轨道布局会在启动时拒绝，读取失败不会向 CDIC 发布部分扇区。

首版不接受 `.cdi`、CHD、cooked 2048 字节扇区、WAVE、`POSTGAP` 或高于 01 的 INDEX。Q 子通道由 CUE 信息生成；未导入外部 `.sub`，R-W 子通道置零，因此不保证依赖 CD+G 或特殊子通道的内容。音频采用保持采样值的方式转换为 Pocket 的 48 kHz I²S，未实现高质量插值滤波。纯 Audio CD 的专用类型识别尚未适配；混合 CD-i 光盘中的 CDDA 音轨保留。

光盘按每次启动选择，不提供运行中的换盘操作。

## 编译和验证

Quartus 工程为 `src/fpga/ap_core.qpf`，目标器件 `5CEBA4F23C8`。本机使用 Quartus Prime Lite 25.1、Questa Altera Starter 2025.2 和 LLVM 23.1.1。其他版本可通过脚本参数指定安装目录：

```powershell
./scripts/build.ps1
./scripts/test.ps1
```

完整构建先编译核心内的文件管理固件，再运行测试、综合、布局布线与时序分析，最后生成反转位序的 `bitstream.rbf_r` 和 SD 卡安装包。固件源码在 `firmware/native_disc/`，生成的 `firmware.mif` 已保留在工程内，单独使用 Quartus 可直接编译。打包器拒绝负时序裕量或源码 / 固件修改后尚未重新编译的结果。原始构建输出在 `src/fpga/output_files/`，详细路径报告在 `build/reports/`，打包后的摘要和源码 / 位流校验在 `dist/`。

验证覆盖实际 CUE 解析代码、实际 RV32I 固件启动、APF 文件名 / 打开 / 按偏移读取、单 BIN / 多 BIN、TOC / CRC / 寻道映射 / 去扰码 / 1284 字扇区传输 / 读取失败，以及 NVRAM、控制器、音频、SDRAM、视频同步与伺服复位。新增完整 1 MiB 启动时限、清零期间的加载 / 刷新，以及真实双线 SPI 命令握手和跨区域返回数据仿真；数据槽测试使用与核心相同的许可模块，按实机日志的 CUE → BIOS → Slave → NVRAM 顺序运行，并检查 BIN 槽和长度限制。

`tb_startup` 将生产启动条件、文件仲裁器、APF 命令处理器、实际光盘固件、异步 FIFO 和 SDRAM 控制器连在一起。它按 OS 2.7 日志先检查 Ready to Run，再服务运行阶段的文件请求，传输完整 512 KiB 模拟 BIOS 及 8 KiB 模拟 Slave，验证 CUE / BIN 打开、菜单保存握手和核心复位。另一个参数场景检查 BIOS 读取失败时 CPU 保持复位；完整 1 MiB 清零仍由 `tb_boot` 验证。

实机验收步骤与当前验证记录见 [docs/validation.md](docs/validation.md)，平台连接见 [docs/architecture.md](docs/architecture.md)。

## 来源与许可

CD-i RTL 来自 [Slamy/CDi_MiSTer](https://github.com/Slamy/CDi_MiSTer)，沿用 GPL-3.0-or-later 和源文件中的许可声明。CPU、Slave MCU 的第三方来源保留在原始文件中。APF 来自 [open-fpga/core-template](https://github.com/open-fpga/core-template)，其框架和 FPGA 厂商文件保留各自许可声明。文件管理助手采用 [PicoRV32](https://github.com/YosysHQ/picorv32)，保留 ISC 许可；新增适配代码与 CUE/BIN 固件使用 GPL-3.0-or-later。`docs/upstream.json` 记录导入源及其校验值。

适配依据为 Analogue 的 [总线规范](https://www.analogue.co/developer/docs/openfpga/bus-communication)、[数据槽](https://www.analogue.co/developer/docs/openfpga/core-definition-files/data-json)、[Host / Target 命令](https://www.analogue.co/developer/docs/openfpga/host-target-commands)和[核心打包格式](https://www.analogue.co/developer/docs/openfpga/packaging-a-core)。
