"""Record the exact local sources retained by this port, without Git assumptions."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
ORIGINS = {
    "CDi_MiSTer": ROOT.parent / "CDi_MiSTer",
    "core-template-1.3.0": ROOT.parent / "core-template-1.3.0",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    entries = []
    imported = set()

    def record(local: Path, origin: str, relative: Path) -> None:
        upstream = ORIGINS[origin] / relative
        if not upstream.is_file():
            raise SystemExit(f"Upstream source missing: {upstream}")
        local_name = local.relative_to(ROOT).as_posix()
        imported.add(local_name)
        entries.append({
            "local": local_name, "origin": origin,
            "upstream_path": relative.as_posix(),
            "upstream_sha256": digest(upstream), "local_sha256": digest(local),
            "modified": upstream.read_bytes() != local.read_bytes(),
        })

    cdi = ROOT / "src/fpga/core/cdi"
    for path in sorted(cdi.rglob("*")):
        relative = Path("rtl") / path.relative_to(cdi)
        if path.is_file() and (ORIGINS["CDi_MiSTer"] / relative).is_file():
            record(path, "CDi_MiSTer", relative)
    record(ROOT / "LICENSE", "CDi_MiSTer", Path("LICENSE"))
    for path in sorted((ROOT / "src/fpga/apf").rglob("*")):
        if path.is_file():
            record(path, "core-template-1.3.0", path.relative_to(ROOT))
    for name in ("ap_core.qpf", "ap_core.qsf"):
        path = ROOT / "src/fpga" / name
        record(path, "core-template-1.3.0", path.relative_to(ROOT))
    for name in ("core_top.sv", "core_bridge_cmd.v", "core.qip", "core_constraints.sdc"):
        path = ROOT / "src/fpga/core" / name
        relative = path.relative_to(ROOT)
        if (ORIGINS["core-template-1.3.0"] / relative).is_file():
            record(path, "core-template-1.3.0", relative)

    pico = ROOT / "src/fpga/core/native_disc/picorv32.v"
    pico_sha = "0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622"
    imported.add(pico.relative_to(ROOT).as_posix())
    entries.append({
        "local": pico.relative_to(ROOT).as_posix(), "origin": "PicoRV32",
        "upstream_path": "picorv32.v",
        "download_url": "https://raw.githubusercontent.com/YosysHQ/picorv32/main/picorv32.v",
        "upstream_sha256": pico_sha, "local_sha256": digest(pico),
        "modified": digest(pico) != pico_sha, "license": "ISC",
    })

    added = [path.relative_to(ROOT).as_posix()
             for path in sorted((ROOT / "src/fpga/core").rglob("*"))
             if path.is_file() and path.suffix in {".sv", ".v", ".vhd", ".svh", ".qip", ".sdc", ".mif"}
             and path.relative_to(ROOT).as_posix() not in imported]
    result = {
        "note": "Imported from the user's local checkouts; no upstream commit identity was available.",
        "origins": [
            {"name": "CDi_MiSTer", "directory": "../CDi_MiSTer",
             "project_url": "https://github.com/Slamy/CDi_MiSTer"},
            {"name": "core-template-1.3.0", "directory": "../core-template-1.3.0",
             "project_url": "https://github.com/open-fpga/core-template"},
            {"name": "PicoRV32", "project_url": "https://github.com/YosysHQ/picorv32",
             "note": "Downloaded main/picorv32.v on 2026-10-03; identity pinned by SHA-256."},
        ],
        "retained_sources": entries, "new_core_sources": added,
        "new_disc_firmware_sources": [p.relative_to(ROOT).as_posix()
            for p in sorted((ROOT / "firmware/native_disc").iterdir()) if p.is_file()],
    }
    destination = ROOT / "docs/upstream.json"
    destination.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Recorded {len(entries)} upstream sources and {len(added)} new core sources.")


if __name__ == "__main__":
    main()
