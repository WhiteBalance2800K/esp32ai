#!/usr/bin/env python3
"""Build the ESP32-C3 target and create the merged ESP Web Tools image."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


FIRMWARE_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = FIRMWARE_DIR.parent
ENV_NAME = "esp32-c3-devkitm-1"
BUILD_DIR = FIRMWARE_DIR / ".pio" / "build" / ENV_NAME
OUTPUT_DIR = REPO_DIR / "web-flasher" / "firmware"
TEMP_OUTPUT = OUTPUT_DIR / ".esp32c3-ai-clock.tmp.bin"
MANIFEST = REPO_DIR / "web-flasher" / "manifest.json"
TEMP_MANIFEST = MANIFEST.with_suffix(".tmp.json")
BOOTLOADER_OFFSET = 0x0
PARTITIONS_OFFSET = 0x8000
BOOT_APP0_OFFSET = 0xE000
APPLICATION_OFFSET = 0x10000
FLASH_SIZE_BYTES = 4 * 1024 * 1024


def tool(name: str) -> str:
    beside_python = Path(sys.executable).with_name(name)
    found = shutil.which(name)
    if beside_python.exists():
        return str(beside_python)
    if found:
        return found
    raise SystemExit(f"missing {name}; install firmware/.pio-venv dependencies first")


def find_boot_app0() -> Path:
    core_dir = Path(os.environ.get("PLATFORMIO_CORE_DIR", Path.home() / ".platformio"))
    path = core_dir / "packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
    if not path.exists():
        raise SystemExit("boot_app0.bin not found; run the PlatformIO build first")
    return path


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def c3_version() -> str:
    config = (FIRMWARE_DIR / "include/config.h").read_text()
    match = re.search(r'^#define FW_VERSION_ESP32_C3 "([^"]+)"$', config, re.MULTILINE)
    if not match:
        raise SystemExit("FW_VERSION_ESP32_C3 not found in include/config.h")
    return match.group(1)


def validate_build_contract() -> None:
    config = (FIRMWARE_DIR / "platformio.ini").read_text()
    required = (
        "platform = espressif32@6.6.0",
        "board = esp32-c3-devkitm-1",
        "board_build.partitions = no_ota.csv",
        "board_build.flash_mode = dio",
        "board_build.f_flash = 40000000L",
        "-D TFT_MOSI=5",
        "-D TFT_MISO=5",
        "-D TFT_SCLK=3",
        "-D TFT_CS=-1",
        "-D TFT_DC=2",
        "-D TFT_RST=6",
        "-D TFT_BL=1",
    )
    missing = [line for line in required if line not in config]
    if missing:
        raise SystemExit("platformio.ini Web build contract changed: " + ", ".join(missing))


def verify_merged_image(image: Path, required: dict[str, Path], boot_app0: Path, version: str) -> None:
    merged = image.read_bytes()
    checks = (
        (PARTITIONS_OFFSET, required["partitions"]),
        (BOOT_APP0_OFFSET, boot_app0),
        (APPLICATION_OFFSET, required["application"]),
    )
    for offset, source in checks:
        data = source.read_bytes()
        if merged[offset : offset + len(data)] != data:
            raise SystemExit(f"merged image mismatch at 0x{offset:x}: {source.name}")
    if len(merged) > FLASH_SIZE_BYTES:
        raise SystemExit("merged image exceeds the 4MB target")
    if version.encode() not in required["application"].read_bytes():
        raise SystemExit("firmware version is not embedded in the application image")
    if str(Path.home()).encode() in merged:
        raise SystemExit("merged image leaks the build machine Home path")

    info = subprocess.run(
        (tool("esptool"), "--chip", "esp32c3", "image-info", str(image)),
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    for expected in ("Flash size: 4MB", "Flash freq: 40m", "Flash mode: DIO", "Chip ID: 5 (ESP32-C3)"):
        if expected not in info:
            raise SystemExit(f"unexpected merged image header: missing {expected}")


def write_manifest(path: Path, version: str, image_name: str) -> None:
    manifest = {
        "name": "AI Clock ESP32-C3",
        "version": version,
        "new_install_prompt_erase": True,
        "new_install_improv_wait_time": 0,
        "builds": [
            {
                "chipFamily": "ESP32-C3",
                "parts": [{"path": f"firmware/{image_name}", "offset": 0}],
            }
        ],
    }
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


def main() -> None:
    validate_build_contract()
    version = c3_version()
    run(tool("pio"), "run", "-e", ENV_NAME, cwd=FIRMWARE_DIR)

    required = {
        "bootloader": BUILD_DIR / "bootloader.bin",
        "partitions": BUILD_DIR / "partitions.bin",
        "application": BUILD_DIR / "firmware.bin",
    }
    missing = [str(path) for path in required.values() if not path.exists()]
    if missing:
        raise SystemExit("missing build outputs: " + ", ".join(missing))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    boot_app0 = find_boot_app0()
    try:
        run(
            tool("esptool"),
            "--chip",
            "esp32c3",
            "merge-bin",
            "-o",
            str(TEMP_OUTPUT),
            "--flash-mode",
            "dio",
            "--flash-freq",
            "40m",
            "--flash-size",
            "4MB",
            hex(BOOTLOADER_OFFSET),
            str(required["bootloader"]),
            hex(PARTITIONS_OFFSET),
            str(required["partitions"]),
            hex(BOOT_APP0_OFFSET),
            str(boot_app0),
            hex(APPLICATION_OFFSET),
            str(required["application"]),
        )
        verify_merged_image(TEMP_OUTPUT, required, boot_app0, version)
        digest = hashlib.sha256(TEMP_OUTPUT.read_bytes()).hexdigest()
        output = OUTPUT_DIR / f"esp32c3-ai-clock-{version}-{digest[:12]}.bin"
        write_manifest(TEMP_MANIFEST, version, output.name)
        generated_manifest = json.loads(TEMP_MANIFEST.read_text())
        if generated_manifest["version"] != version:
            raise SystemExit("generated manifest version mismatch")
        if output.exists():
            if output.read_bytes() != TEMP_OUTPUT.read_bytes():
                raise SystemExit("content hash collision for immutable Web image")
        else:
            TEMP_OUTPUT.replace(output)
        # The final mutable step is only this pointer switch. If it fails, the
        # old manifest still references its old immutable, verified image.
        TEMP_MANIFEST.replace(MANIFEST)
    finally:
        TEMP_OUTPUT.unlink(missing_ok=True)
        TEMP_MANIFEST.unlink(missing_ok=True)
    print(f"Web image: {output} ({output.stat().st_size} bytes)")
    print(f"Manifest: {MANIFEST} (version {version})")


if __name__ == "__main__":
    main()
