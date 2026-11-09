#!/usr/bin/env python3
"""Check qemu.sh's desktop-device arguments without starting a guest."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    bindir = root / "bin"
    bindir.mkdir()
    qemu = bindir / "qemu-system-x86_64"
    qemu.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_ARGV"\n')
    qemu.chmod(0o755)
    for name in ("code", "vars", "disk.img"):
        (root / name).touch()
    esp = root / "esp/X86_64_GENERIC"
    (esp / "EFI/BOOT").mkdir(parents=True)
    (esp / "EFI/BOOT/BOOTX64.EFI").touch()
    (esp / "boot").mkdir()
    (esp / "boot/loader.conf").touch()
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
               OBJDIR=directory, OVMF_CODE=str(root / "code"),
               OVMF_VARS=str(root / "vars"), TEST_ARGV=str(root / "args"),
               DISPLAY=":99", DISPLAY_BACKEND="gtk")
    env.pop("SERIAL_LOG", None)
    env.pop("SERIAL_PIPE", None)
    env.pop("MONITOR_SOCKET", None)
    expected = ("qemu-xhci,id=xhci", "usb-kbd,bus=xhci.0",
                "usb-mouse,bus=xhci.0")
    for name, options, count in (
        ("serial", ("--serial", "--desktop-devices"), 1),
        ("gui", ("--gui", "--desktop-devices"), 1),
        ("default", ("--serial",), 0),
    ):
        subprocess.run([str(repo / "tools/linux/qemu.sh"), "--disk", *options],
                       env=env, check=True, capture_output=True, text=True)
        args = (root / "args").read_text().splitlines()
        devices = [args[i + 1] for i, arg in enumerate(args[:-1])
                   if arg == "-device"]
        assert args.count("-vga") == count, (name, args)
        assert all(devices.count(device) == count for device in expected), (
            name, devices)
        print(f"{name}: ok")

    socket_path = root / "monitor socket"
    monitor_env = dict(env, MONITOR_SOCKET=str(socket_path))
    subprocess.run([str(repo / "tools/linux/qemu.sh"), "--serial", "--disk",
                    "--desktop-devices"], env=monitor_env, check=True,
                   capture_output=True, text=True)
    args = (root / "args").read_text().splitlines()
    assert f"unix:{socket_path},server=on,wait=off" in args
    socket_path.write_text("keep")
    result = subprocess.run([str(repo / "tools/linux/qemu.sh"), "--serial",
                             "--disk"], env=monitor_env, capture_output=True,
                            text=True)
    assert result.returncode != 0 and "already exists" in result.stderr
    assert socket_path.read_text() == "keep"
    monitor_env["MONITOR_SOCKET"] = str(root / "bad,socket")
    result = subprocess.run([str(repo / "tools/linux/qemu.sh"), "--serial",
                             "--disk"], env=monitor_env, capture_output=True,
                            text=True)
    assert result.returncode != 0 and "comma" in result.stderr
    print("monitor: ok")
