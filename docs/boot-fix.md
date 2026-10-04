# 启动修复记录

## 0.2.6-dev：CDI/2352 加载阻塞与显示就绪条件

用户日志 `CDiPocket.CDi_20200129_004803.txt` 显示 OS 2.7 正常完成框架启动、全部 128 次 BIOS 读取、CUE 读取和 BIN 打开。所选 Zelda’s Adventure 的 BIN 长度为 517204800 字节；没有框架 Fatal。SD 卡上位流 SHA-256 与 0.2.5-dev 包一致。日志没有 MCD212 寄存器值或音频状态，不能据此证明 CPU、视频、游戏音轨已经正常运行。

读取 SD 卡上的原始 CUE 后确认其轨道声明为 `TRACK 01 CDI/2352`。旧生产解析器在 FILE 行已打开 BIN、取得长度后，于 TRACK 行返回 `DISC_UNSUPPORTED`（2）；助手诊断为 `0x00030002`，不能置位 `disc_ready`，机器持续复位。这与日志最后停在 BIN 打开的顺序一致，可以解释黑屏和无声。直接调用生产 C 代码处理这份 113 字节 CUE 和实际 BIN 长度，旧版确实返回 2。

新增 `CDI/2352` 为 2352 字节 Mode 2 原始轨道的别名，沿用现有扇区、TOC 和 Q 子通道处理；无需修改 CUE 或转换 BIN。此项是 CUE 轨道类型兼容，与用户明确排除的 `.cdi` 文件支持无关。[GNU ccd2cue 的轨道类型说明](https://www.gnu.org/software/ccd2cue/manual/html_node/MODE-_0028Compact-Disc-fields_0029.html)也将其定义为 CD-i Mode 2 数据。修正后，同一 CUE 解析成功，1 轨、219900 个扇区、lead-out 为 220050；抽查实际 BIN 的首扇区、相邻扇区、中间和末扇区均成功生成记录，Q CRC 正确。检查报告为 `build/media_check_before.json` / `build/media_check_after.json`；这是文件与扇区检查，不代表游戏已通过实机运行。

七个原生光盘单元测试覆盖该别名、大小写、原始 / 扰码扇区、TOC / Q 与 MODE2/2352 的结果一致性，并保持 CDI/2336、CDI/2048 拒绝。实际 RV32I 和完整启动集成测试改用 CDI/2352 合成 CUE，检查原生打开 BIN、就绪、BIOS / Slave 传输和错误复位保护。新文件管理固件已重新编译，并通过 Quartus 更新 RAM 初始化后重新生成位流；原布局布线和时序网络保持一致。

0.2.5-dev 的 `video_initialized` 要求 DCR1.DE 且至少一个图像平面编码非零，但原 MCD212 渲染器不使用 DE 位，独立硬件光标也可在两个图像平面关闭时输出有效画面。旧条件能永久遮挡这种画面；此前 `tb_video` 人工提供就绪信号，没有覆盖其实际生成过程。0.2.6-dev 根据渲染器的实际条件接受独立光标、开启 ICA 且编码非零的平面 A / B。初始化仍锁存至复位，后续纯色或空白场景不会重新被遮挡。原来的加载黑帧、几何检查和完整帧切换保持。

新增 `tb_mcd_video` 将真实 MCD212、真实 ICA 控制器与 Pocket 视频适配器相连，通过 CPU 寄存器写入和模拟内存突发执行自建 ICA 指令。它覆盖纯背景保持黑屏、DE 清零且双平面关闭时实际白色光标到达 APF、关闭光标后的纯色场景，以及复位后的 A / B 平面初始化。旧条件的复现日志为 `build/sim/tb_mcd_video_before.log`，最终回归为 `build/sim/tb_mcd_video.log`。这证明旧判定存在永久黑屏路径，不等于证明实机当时必然使用同一寄存器组合；仍需 Pocket 复测 BIOS 界面和进入游戏后的音画。

为让保留的 MCD 模块能在 Questa 中独立编译，补齐 ICA 的类型头引用，将共享变量声明移到首次过程引用之前，给 DYUV 的过程输出声明变量类型，并限定调试字符串仅用于 Verilator。未更改图像解码、CPU、光盘或音频算法。测试使用自建数据，不依赖商业 BIOS 或游戏。

## 0.2.5-dev：加载黑屏与完整帧切换

用户反馈选盘确认后短暂出现上一张光盘的画面，随后闪过蓝绿色纯色，再进入 CD-i 界面。旧视频适配器在机器复位期间只将 DE 关闭，没有发送完整黑帧；这不能主动覆盖 Pocket scaler 先前保存的画面。纯色的具体实机来源尚未验证，本版同时遮挡 BIOS 尚未初始化显示的输出。

视频输出仍使用原有、不暂停的 30 MHz 时钟。独立 `video_timing` 与 `pocket_video_bus` 生成已声明的 768×280 PAL 逐行黑帧；只有平台上电复位会重置它，资源加载、机器复位和加载失败时继续发送黑色活动像素与 APF 的单拍 HS / VS、SKIP 和帧元数据。无需增加帧缓存。

MCD212 在 DCR1 的显示使能开启且至少一个图像平面编码方法已设置时，锁存 `video_initialized`，系统复位清除。后续纯背景场景不会撤销此标志。输出适配器再要求初始化之后的两个完整帧具有一致的 720 / 768 像素行宽、240 / 280 活动行和隔行模式。先结束当前黑帧，在无活动像素的间隔等原生 VS，再连同 VS 元数据一起切换；不会从原生半帧开始。机器复位或内部系统复位重新显示黑屏并重新检查。正常运行中的菜单暂停保持已完成的游戏帧，不重新启动黑屏流程。

`tb_video` 增加长时间复位、BIOS 初始化颜色、错误行宽保持黑屏、切换首个 VS / 元数据检查，原有 PAL / NTSC / 隔行尺寸及菜单暂停检查继续保留。检查不执行真实 BIOS，也不模拟 Pocket scaler；实际视觉效果仍需实机验收。核心只能在 FPGA 配置和 PLL 时钟可用后输出黑帧，框架在这之前显示的内容不由核心控制。APF 视频信号格式依据[总线文档](https://www.analogue.co/developer/docs/openfpga/bus-communication)。

## 0.2.4-dev：Pocket 菜单暂停

用户确认 0.2.3-dev 已可正常进入游戏，随后报告 Menu Button 打开 Pocket 菜单时游戏仍运行。此前 `osnotify_inmenu` 仅触发脏 NVRAM 保存，没有接入机器运行条件。

本版新增 `pocket_pause`，同步菜单通知后，在垂直消隐、SDRAM 读写请求撤销且最后的数据/确认已被消费时关闭机器时钟。CPU、MCD212、CDIC、Slave、标准控制器和扇区缓存保持原状态；文件助手、APF 命令处理、SDRAM 刷新和 NVRAM Bridge 端继续运行。菜单期间 I²S 输出完整静音帧，退出后恢复；恢复时先排空后台刷新，核心重置则强制打开机器时钟。

新增 `tb_pause` 验证真实 SDRAM 四字突发和 busy 下降沿先被消费、暂停期间状态/控制器不推进、刷新间隔、音频静音/恢复、重复菜单及复位。`tb_framework` 通过实际双线 SPI 发出 `00B0`，检查暂停期间 Host 查询仍回应 Running。`tb_native_disc` 检查暂停中完成的 APF 读取及中途停止的扇区流，恢复后逐字核对数据。`tb_video` 检查暂停仅发生于消隐，恢复后视频计数继续。新版仍需 Pocket 实机确认菜单行为。

## 0.2.3-dev：Ready to Run 与文件请求顺序

用户的 `CDiPocket.CDi_20200128_041603.txt` 日志确认 CUE、BIOS、Slave 加载许可均成功，CUE / BIOS 的延迟加载表已更新，Slave 数据已传输，`008F`、`0090` 和 Dock 通知也成功。框架随后检查 Ready to Run，以 `Core not ready to run` 退出；日志中尚无 BIOS / CUE 的 Target 文件命令被执行。

0.2.2-dev 将框架的 `status_setup_done` 与 BIOS / 光盘初始化完成绑在一起，并在 `008F` 后直接发出延迟文件请求。这些请求占用了 Target 命令寄存器，而实机此时先检查 `0140`。不能依赖该固件版本在这段启动路径中服务普通文件请求。

0.2.3-dev 使用独立的框架启动与机器启动条件：资源许可/传输完成、加载队列可用且未溢出后，锁存框架 Ready，优先留出 Target 寄存器发送 `0140`。只有收到 `0011 Reset Exit` 后，文件仲裁器和助手才开始 BIOS / CUE / BIN 操作。CD-i CPU 的复位仍需要实际 BIOS、Slave、RAM 与光盘全部就绪；APF 框架处于 Running 时，后台文件初始化可继续执行。框架 Ready 不随后续核心复位或数据槽操作清除，避免再次发送启动通知。

新增 `tb_startup` 使用生产 `pocket_startup` / `pocket_file_io`、实际命令处理器、实际 RV32I 固件及厂商 FIFO / RAM 模型。模拟 Host 严格按实机顺序，只在 Ready to Run 与 Reset Exit 之后处理文件请求。恢复旧条件时得到 `Core not ready to run: target register 636d0180`；测试确认资源已完成且 FIFO 未溢出，日志见 `build/sim/tb_startup_legacy.log`。

新流程检查全部 128 次 4 KiB BIOS 请求，在 SDRAM 引脚核对 262144 个 16 位字的顺序与内容，并核对全部 8192 个 Slave 字节、CUE / 多 BIN 初始化、菜单保存握手与复位。另一个场景注入 BIOS 读取失败，必须保持 CD-i CPU 复位。此集成测试采用 4 KiB 基础 RAM 清零以缩短执行时间；独立 `tb_boot` 保持完整 1 MiB 清零。

官方[启动流程](https://www.analogue.co/developer/docs/openfpga/core-boot-process)描述 Ready to Run 后的 Reset Exit，以及运行阶段的数据读写。此次兼容处理依据 OS 2.7 的实际日志，而不把其启动阶段的文件服务行为推广到所有固件版本。

## 0.2.2-dev：延迟加载 CUE 的许可

用户在 Pocket OS 2.7 上重试 0.2.1-dev，日志 `CDiPocket.CDi_20200128_035334.txt` 显示首次 Request Status 已返回 `0002`（Setup），适配器通知也成功完成。随后框架针对 77 字节的 `Hotel Mario.cue`，连续十次请求 `0082`、槽 ID 0，每次均收到 `0002`（check later），500 ms 后以 `RW: Host commands ignored` 退出。故障发生在解析 CUE 之前。

旧许可条件仅接受槽 1 / 2 / 3，漏掉了延迟加载的 CUE 槽 0。`deferload` 控制资源数据是否自动传输，不能据此拒绝启动时的许可查询。0.2.2-dev 接受符合 `data.json` 长度限制的 CUE 和 BIN 元数据请求，保留 BIOS / Slave / NVRAM 的固定长度检查及 NVRAM 暂停握手。CUE 大小也从已接受的请求记录，不只依赖后续表更新；文件仍由助手按需读取。

上一轮 SPI 测试直接从 Slave 请求开始，未覆盖实机 CUE 最先请求的顺序。新增这个请求后，旧条件重现 `0082 returned 4f4b0002; expected 0000`，日志保存在 `build/sim/tb_framework_cue_before.log`。现在测试实例化生产代码使用的 `pocket_slot_policy`，通过实际双线 SPI 依次请求 CUE、BIOS、Slave、NVRAM，并检查 BIN 槽、大小边界及未知槽拒绝；不再另写一份简化的测试许可条件。

## 0.2.1-dev：Booting 超时

Pocket OS 2.7 的实机反馈：选择 CUE 后出现 `RS: Host commands ignored`，并退出核心。用户日志确认位流已成功加载，框架连续十次发出 `0000 Request Status`，每次均收到 `0001`（Booting）；尚未开始传输 BIOS、Slave 或 CUE。

0.2.0-dev 的 `status_boot_done` 等待整个 1 MiB 基础 RAM 清零完成。清零包含 524288 次 SDRAM 写入，需要超过 100 ms，超过框架首次状态轮询窗口。这会触发启动错误，即使命令处理器正常回应。

0.2.1-dev 将“可接收资源”和“机器内存准备完成”分开：SDRAM 物理初始化及短暂等待结束后，约 0.5 ms 即报告 Setup。RAM 清零在 Setup 阶段继续执行；Slave / BIOS 加载队列可暂停清零以避免溢出，期间维持 SDRAM 刷新。CPU 仍等待 RAM、BIOS、Slave 和 CUE / BIN 初始化全部完成才解除复位。

新增 `tb_boot` 使用完整 1 MiB 清零、实际 SDRAM 控制器、实际异步加载 FIFO 和实际命令处理器。旧启动条件通过 `LEGACY_BOOT=1` 重现十次 `0001`；新条件必须在 100 ms 时连续返回 Setup，随后完成全部清零并正确进入 Running。还在清零期间传入完整 8 KiB Slave 数据，校验无溢出、顺序和刷新间隔。

新增 `tb_framework` 使用实际 APF 双线 SPI 收发器和命令处理器，无强制内部状态。它发现并修复了跨 Bridge 地址区域切换时上一笔读取结果丢失的问题；原生 RAM 与 NVRAM 的返回值现在经过统一的缓冲协议。测试还覆盖首次数据槽请求的 ID / 大小握手、Ready to Run、Reset Enter / Exit 后的状态，以及 OS 的适配器 / Dock 通知。

命令处理器补充显式上电状态。数据槽请求先发布寄存器再等待消费者确认，避免用上一条请求的 ID / 大小作出决定；Running 状态优先于已完成 Setup 的状态，避免解除复位后仍报告 Idle。

此次修复有启动日志和回归仿真支持。修复后的位流仍需在用户的 Pocket 上确认能进入 BIOS，以及进一步验证真实光盘读取和游戏运行。

协议依据：[Analogue 启动流程](https://www.analogue.co/developer/docs/openfpga/core-boot-process)、[Host / Target 命令](https://www.analogue.co/developer/docs/openfpga/host-target-commands)与[总线通信](https://www.analogue.co/developer/docs/openfpga/bus-communication)。
