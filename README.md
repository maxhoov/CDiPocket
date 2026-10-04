# CDiPocket

A Philips CD-i Mono I core for Analogue Pocket openFPGA, ported from [CDi_MiSTer](https://github.com/Slamy/CDi_MiSTer) using the APF framework and Pocket pin assignments from [core-template](https://github.com/open-fpga/core-template).

This is **version 0.1.0, an engineering validation release**. It includes HDL, a Quartus project, native CUE/BIN access and simulations.

The core outputs complete black frames while loading assets and initializing the BIOS display. Once an image plane or the independent hardware cursor is enabled and two consecutive frames have matching geometry, it switches to the CD-i picture at a frame boundary. Display readiness no longer requires DCR1.DE, which the original renderer does not use. Opening the Pocket menu pauses the machine and disc cache after vertical blanking and pending memory transfers, and mutes audio. Closing the menu resumes execution. APF file operations, SDRAM refresh, and NVRAM saving remain active during the pause.

## Initial release scope

Included hardware:

- SCC68070 / TG68K CPU
- MCD212 video controller
- CDIC
- 68HC05 Slave MCU and servo control
- Basic CDDA / XA ADPCM audio
- CD-ROM
- MK48T08B with 8 KiB NVRAM / RTC
- Standard directional input and a two-button controller

VMPEG, the Digital Video Cartridge, MPEG-1 decoding, CHD, mouse / light gun input, and other MiSTer platform extensions are excluded. The system targets its original clock of approximately 30 MHz.

## Installation and use

1. Extract `CDiPocket_0.1.0_2026-10-04.zip` to the root of the Pocket SD card.
2. Provide the system BIOS as `cdi200.rom` (524288 bytes) and the Slave 2.0 firmware as `slave.rom` (8192 bytes). Place both in `Assets/cdi/common/`. BIOS, Slave ROM, and game images are not included.
3. Place the original `.cue` file and all referenced `.bin` files in `Assets/cdi/common/` or a subdirectory. Preserve the filenames and relative paths used in the CUE. For example, place `Example.cue` and `Example.bin` together in `Assets/cdi/common/Example/`.
4. Select the `.cue` file when launching the core, then select Play in the CD-i system interface. Multiple BIN files are opened automatically according to the CUE. Disc images are accessed read-only.

When upgrading from an earlier release, remove the old `Cores/maxhoov.CDi/` directory to avoid duplicate core entries.

Firmware MD5 hashes validated by the upstream project:

| Firmware       | MD5                                |
| -------------- | ---------------------------------- |
| System BIOS    | `2969341396aa61e0143dc2351aaa6ef6` |
| Slave firmware | `3d20cf7550f1b723158b42a1fd5bac62` |

Pocket A maps to CD-i button 1 (one dot), B to button 2 (two dots), and X presses both buttons. The directional pad moves the pointer. The first standard controller connected through the Dock uses the same directional and button mappings. Analog sticks and a second controller are not supported.

Press the Menu Button to pause the game and audio; close the Pocket menu to resume. The pause waits for the next vertical blank and completion of the current memory access. It preserves CPU, Slave MCU, CDIC, video, and audio track state. Core reset remains available from the menu.

PAL is the default. After changing `Video region (reset)`, use the Pocket's core reset command. The core supports MCD212 PAL / NTSC timing, 720 / 768 pixel widths, and interlaced field markers.

## Disc formats and limits

The core directly accepts BINARY files with `MODE1/2352`, `MODE2/2352`, `CDI/2352`, and `AUDIO` tracks. It supports:

- Single or multiple BIN files
- Up to 99 consecutively numbered tracks and 99 distinct BIN files
- `INDEX 00/01`, `PREGAP`, and `FLAGS PRE/DCP/4CH`
- Descrambling of common raw data sectors
- Filenames containing spaces or UTF-8 characters
- CRLF line endings, a UTF-8 BOM, case-insensitive CUE commands, and common descriptive metadata

`CDI/2352` is a CUE track type for raw CD-i Mode 2 sectors. It is distinct from the DiscJuggler `.cdi` image format, which is not supported.

A small RV32I file manager embedded in the FPGA parses the CUE and checks BIN lengths at startup. During execution, it reads 2352-byte sectors from the SD card on demand, supplies TOC data, Q subchannel data, and CRCs, and passes the sector records to the original CDIC cache. Gaps and the final 128-sector lead-out are synthesized at runtime. No intermediate disc image is created, and the full disc is not loaded into memory.

The following limits apply:

- CUE files must not exceed 32 KiB.
- Full paths must be shorter than 256 bytes and remain inside this platform's Assets directory.
- BIN lengths must be multiples of 2352 bytes.
- Absolute disc addresses, including the lead-out, must remain below 100 minutes.
- The first track's `INDEX 01` corresponds to absolute MSF 00:02:00. A first-track pregap exceeding 150 sectors is rejected.

Missing files, truncated BIN files, and invalid track layouts are rejected during startup. A failed read does not publish a partial sector to the CDIC.

The initial release does not accept `.cdi`, CHD, cooked 2048-byte sectors, WAVE, `POSTGAP`, or INDEX values above 01. Q subchannel data is generated from the CUE. External `.sub` files are not imported, and R-W subchannels are filled with zeros, so content requiring CD+G or special subchannel data is not guaranteed to work. Audio is converted to the Pocket's 48 kHz I2S output by holding sample values; high-quality interpolation is not implemented. Dedicated recognition of pure Audio CDs has not been adapted, although CDDA tracks in mixed CD-i discs are retained.

A disc is selected at each launch. Disc swapping during execution is not supported.

## Building and validation

The Quartus project is `src/fpga/ap_core.qpf`, targeting the Pocket's `5CEBA4F23C8` FPGA. The current build uses Quartus Prime Lite 25.1, Questa Altera Starter 2025.2, and LLVM 23.1.1. Installation paths can be supplied through script parameters.

```powershell
./scripts/build.ps1
./scripts/test.ps1
```

A full build compiles the embedded file manager, runs the tests, performs synthesis, fitting, and timing analysis, then generates the bit-reversed `bitstream.rbf_r` and SD card installation package. Firmware sources are in `firmware/native_disc/`. The generated `firmware.mif` is included so the FPGA project can also be compiled directly in Quartus. The packager rejects negative timing slack and builds whose HDL, project configuration, or firmware has changed without being rebuilt.

Raw build outputs are in `src/fpga/output_files/`, detailed timing reports in `build/reports/`, and packaged summaries and source / bitstream checksums in `dist/`.

Validation covers the actual CUE parser and RV32I firmware startup; APF filename, open, and offset-read operations; single and multiple BIN files; TOC, CRC, seek mapping, descrambling, 1284-word sector transfers, and read failures. It also covers NVRAM, controllers, audio, SDRAM, video synchronization, and servo reset. Additional tests cover the complete 1 MiB memory clear within the startup deadline, loading and refresh during clearing, physical two-wire SPI command handshakes, and data returned across bridge regions. Data slot tests use the production permission module and follow the hardware log's CUE -> BIOS -> Slave -> NVRAM loading order, including BIN slot and size-limit checks.

`tb_startup` connects the production startup conditions, file arbiter, APF command handler, actual disc firmware, asynchronous FIFO, and SDRAM controller. Following the Pocket OS 2.7 sequence, it checks Ready to Run before servicing runtime file requests, transfers a complete 512 KiB synthetic BIOS and 8 KiB synthetic Slave ROM, and verifies CUE / BIN opening, menu save handshakes, and core reset. A separate scenario checks that a failed BIOS read keeps the CPU in reset. `tb_boot` verifies the full 1 MiB memory clear.

Hardware acceptance steps and current results are documented in [docs/validation.md](docs/validation.md). Platform connections are described in [docs/architecture.md](docs/architecture.md).

## Sources and licenses

The CD-i RTL comes from [Slamy/CDi_MiSTer](https://github.com/Slamy/CDi_MiSTer), retaining GPL-3.0-or-later and the license notices in the source files. Third-party CPU and Slave MCU attribution remains in the original files. The APF framework comes from [open-fpga/core-template](https://github.com/open-fpga/core-template); its framework and FPGA vendor files retain their respective license notices. The file manager uses [PicoRV32](https://github.com/YosysHQ/picorv32), retaining its ISC license. New adaptation code and CUE/BIN firmware use GPL-3.0-or-later. Imported sources and their checksums are recorded in `docs/upstream.json`. The `cdi.bin` image comes from [spiritualized1997's openFPGA-Platform-Art-Set](https://github.com/spiritualized1997/openFPGA-Platform-Art-Set). Credit for this artwork belongs to that project. The upstream project permits openFPGA developers to use its platform images with their cores on Analogue's openFPGA.

The port follows Analogue's [bus communication specification](https://www.analogue.co/developer/docs/openfpga/bus-communication), [data slot definition](https://www.analogue.co/developer/docs/openfpga/core-definition-files/data-json), [Host / Target commands](https://www.analogue.co/developer/docs/openfpga/host-target-commands), and [core packaging format](https://www.analogue.co/developer/docs/openfpga/packaging-a-core).
