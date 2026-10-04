"""Validate the final Quartus build and package an SD-card installation."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "src/fpga"
OUT = FPGA / "output_files"


def source_digest() -> str:
    digest = hashlib.sha256()
    for path in sorted(list(FPGA.rglob("*")) + list((ROOT / "firmware").rglob("*"))):
        if path.is_file() and path.suffix in {".sv", ".svh", ".v", ".vhd", ".sdc", ".qip", ".qsf", ".qpf", ".tcl", ".mif", ".qdf", ".c", ".h", ".S", ".ld"} \
                and not any(part in {"db", "incremental_db", "output_files"} for part in path.parts):
            digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def main() -> None:
    fit = (OUT / "ap_core.fit.summary").read_text()
    timing = (OUT / "ap_core.sta.summary").read_text()
    if "Found combinational loop" in (OUT / "ap_core.sta.rpt").read_text():
        raise SystemExit("Timing analysis found a combinational loop. Refusing to package this build.")
    if not fit.startswith("Fitter Status : Successful") or "5CEBA4F23C8" not in fit:
        raise SystemExit("A successful fit for Pocket's 5CEBA4F23C8 is required.")
    slacks = [float(value) for value in re.findall(r"Slack\s*:\s*(-?[\d.]+)", timing)]
    if not slacks or min(slacks) < 0:
        raise SystemExit("Timing has not passed. Refusing to package this build.")
    rbf_path = OUT / "ap_core.rbf"
    rbf = rbf_path.read_bytes()
    if len(rbf) < 1000000:
        raise SystemExit("Missing or incomplete Pocket bitstream.")
    for config in (FPGA / "ap_core.qsf", FPGA / "ap_core.qpf"):
        if config.stat().st_mtime > rbf_path.stat().st_mtime:
            raise SystemExit(f"Project changed after compilation: {config.relative_to(ROOT)}")
    for source_dir in (FPGA / "core", FPGA / "apf"):
        for path in source_dir.rglob("*"):
            if path.suffix in {".sv", ".v", ".vhd", ".svh", ".sdc", ".qip", ".mif"} \
                    and path.stat().st_mtime > rbf_path.stat().st_mtime:
                raise SystemExit(f"Source changed after compilation: {path.relative_to(ROOT)}")
    firmware_mif = FPGA / "core/native_disc/firmware.mif"
    for path in (ROOT / "firmware/native_disc").iterdir():
        if path.is_file() and path.stat().st_mtime > firmware_mif.stat().st_mtime:
            raise SystemExit(f"Disc firmware source changed after its build: {path.relative_to(ROOT)}")
    simulation_tests = {}
    for top, marker in {
        "tb_adapters": "ALL ADAPTER TESTS PASSED",
        "tb_memory": "ALL MEMORY TESTS PASSED",
        "tb_video": "ALL VIDEO TESTS PASSED",
        "tb_mcd_video": "ALL MCD VIDEO TESTS PASSED",
        "tb_servo": "ALL SERVO TESTS PASSED",
        "tb_native_disc": "ALL NATIVE DISC TESTS PASSED",
        "tb_framework": "ALL FRAMEWORK TESTS PASSED",
        "tb_boot": "ALL BOOT TESTS PASSED",
        "tb_startup": "ALL STARTUP TESTS PASSED",
        "tb_startup_failure": "ALL STARTUP FAILURE TESTS PASSED",
        "tb_pause": "ALL PAUSE TESTS PASSED",
    }.items():
        transcript = ROOT / f"build/sim/{top}.log"
        content = transcript.read_text(errors="replace") if transcript.is_file() else ""
        passed = marker in content and not re.search(r"\*\* (Fatal|Error):", content)
        if top == "tb_framework":
            passed = passed and all(required in content for required in (
                "PASS OS 2.7 CUE-first deferred-slot startup permissions using production policy",
                "PASS BIN slot, size limits and unknown-slot rejection over physical SPI",
                "PASS OS menu enter/exit pauses and resumes via physical SPI; host remains responsive",
            ))
        if top == "tb_native_disc":
            passed = passed and all(required in content for required in (
                "PASS native CDI/2352 CUE parsed and BIN opened without conversion",
                "PASS pending APF sector completion while paused",
                "PASS mid-sector pause preserves streaming position and valid pulses",
            ))
        if top == "tb_video":
            passed = passed and all(required in content for required in (
                "PASS menu freezes video in vertical blank and resumes timing without reset",
                "PASS complete continuous black frames while machine held in reset",
                "PASS BIOS backdrop colors suppressed before display initialization",
                "PASS malformed native geometry keeps complete black frames",
                "PASS native video begins at VS after matching complete frames",
            ))
        if top == "tb_mcd_video":
            passed = passed and all(required in content for required in (
                "PASS actual MCD backdrop remains hidden before cursor or image programming",
                "PASS actual MCD cursor-only picture reaches APF with DCR1.DE clear and image planes off",
                "PASS later uniform scenes keep native video live after cursor is disabled",
                "PASS actual MCD plane A initializes video with DE clear after warm reset",
                "PASS actual MCD plane B initializes video with plane A off and DE clear",
            ))
        if not passed:
            raise SystemExit(f"A passing {top} simulation is required before packaging.")
        simulation_tests[top] = {
            "passed": passed, "transcript_sha256": hashlib.sha256(content.encode()).hexdigest(),
        }
    core = json.loads((ROOT / "core.json").read_text())["core"]["metadata"]
    identity = f"{core['author']}.{core['shortname']}"
    dist = ROOT / "dist"
    install = dist / "sdcard"
    core_dir = install / "Cores" / identity
    core_dir.mkdir(parents=True, exist_ok=True)
    package_files = []
    for name in ("audio", "core", "data", "input", "interact", "variants", "video"):
        content = (ROOT / f"{name}.json").read_bytes()
        json.loads(content)
        destination = core_dir / f"{name}.json"
        destination.write_bytes(content)
        package_files.append(destination)
    reverse = bytes(int(f"{value:08b}"[::-1], 2) for value in range(256))
    bitstream = rbf.translate(reverse)
    assert bitstream.translate(reverse) == rbf
    destination = core_dir / "bitstream.rbf_r"
    destination.write_bytes(bitstream)
    package_files.append(destination)
    platforms = install / "Platforms"
    platforms.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "platforms/cdi.json", platforms / "cdi.json")
    package_files.append(platforms / "cdi.json")
    images = platforms / "_images"
    images.mkdir(exist_ok=True)
    platform_image = images / "cdi.bin"
    shutil.copy2(ROOT / "cdi.bin", platform_image)
    package_files.append(platform_image)
    (install / "Assets/cdi/common").mkdir(parents=True, exist_ok=True)
    (install / "Saves/cdi/common").mkdir(parents=True, exist_ok=True)
    validation = {
        "device": "5CEBA4F23C8", "source_sha256": source_digest(),
        "bitstream_sha256": hashlib.sha256(bitstream).hexdigest(),
        "platform_image_sha256": hashlib.sha256(platform_image.read_bytes()).hexdigest(),
        "bitstream_bytes": len(bitstream), "minimum_reported_slack_ns": min(slacks),
        "hardware_validated": False, "rom_or_game_assets_included": False,
        "disc_format": "native CUE/BIN (2352-byte raw sectors)",
        "embedded_firmware_sha256": hashlib.sha256(firmware_mif.read_bytes()).hexdigest(),
        "simulation_tests": simulation_tests,
    }
    (dist / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
    (dist / "fit.summary").write_text(fit)
    (dist / "timing.summary").write_text(timing)
    archive = dist / f"{identity}_{core['version']}_{core['date_release']}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for path in sorted(package_files):
            package.write(path, path.relative_to(install).as_posix())
        for directory in ("Assets/cdi/common", "Saves/cdi/common"):
            package.write(install / directory, directory + "/")
    print(f"Created {archive.relative_to(ROOT)} ({len(bitstream):,} byte bitstream)")


if __name__ == "__main__":
    main()
