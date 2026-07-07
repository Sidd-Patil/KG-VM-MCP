#!/usr/bin/env python3
"""FastMCP server — VM management via Apple Virtualization.framework."""

import json
import os
import select
import shutil
import subprocess
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# ── Paths ─────────────────────────────────────────────────────────────────────

_SERVER_DIR  = Path(__file__).parent
_PROJECT_DIR = _SERVER_DIR.parent
BINARY       = _PROJECT_DIR / "vm-helper" / ".build" / "release" / "VMHelper"
SEED_ISO     = _PROJECT_DIR / "images" / "seed.iso"
UBUNTU_IMG   = _PROJECT_DIR / "images" / "ubuntu-22.04-arm64.img"
VM_BASE_DIR  = Path.home() / ".vm-mcp" / "vms"
SENTINEL     = "__VM_DONE__"

mcp = FastMCP("vm-mcp")

# ── Internal helper ───────────────────────────────────────────────────────────

def _run_helper(*args: str) -> dict:
    """Run vm-helper synchronously and return parsed JSON output."""
    result = subprocess.run(
        [str(BINARY), *args],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "success": False,
            "error": result.stderr.strip() or result.stdout.strip() or "no output from vm-helper",
        }

# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_vms() -> dict:
    """List all VMs and their current state."""
    return _run_helper("list")


@mcp.tool()
def create_vm(
    name: str,
    disk_image_path: str = str(UBUNTU_IMG),
    memory_mb: int = 2048,
    cpu_count: int = 2,
) -> dict:
    """
    Create a new VM from an Ubuntu raw disk image.

    The image is copied into the VM's directory so each VM has its own
    independent writable disk. First boot runs cloud-init (serial-getty
    autologin is enabled via seed.iso).

    Args:
        name: VM name — letters, numbers, hyphens, underscores only.
        disk_image_path: Path to the Ubuntu 22.04 ARM64 raw disk image.
                         Defaults to the project's images/ubuntu-22.04-arm64.img.
        memory_mb: RAM in MB (512–16384). Default 2048.
        cpu_count: vCPU count (1–8). Default 2.
    """
    src = Path(disk_image_path).expanduser()
    if not src.exists():
        return {"success": False, "error": f"Disk image not found: {src}"}
    if not SEED_ISO.exists():
        return {"success": False, "error": f"Seed ISO not found: {SEED_ISO} — run prepare_image.sh first"}

    # Swift binary sets up the VM directory, config, and a blank placeholder disk.
    # It takes isoPath (the cloud-init seed ISO) as its second argument.
    result = _run_helper("create", name, str(SEED_ISO), str(memory_mb), str(cpu_count))
    if not result.get("success"):
        return result

    # Replace the blank placeholder disk with the actual Ubuntu image.
    # Use APFS cloning (cp -c) for an instant copy-on-write clone; fall back
    # to shutil.copy2 on non-APFS volumes.
    vm_disk = VM_BASE_DIR / name / "disk.img"
    try:
        result_cp = subprocess.run(
            ["cp", "-c", str(src), str(vm_disk)],
            capture_output=True,
        )
        if result_cp.returncode != 0:
            shutil.copy2(src, vm_disk)
    except OSError as e:
        _run_helper("delete", name)  # clean up the half-created VM
        return {"success": False, "error": f"Failed to copy disk image: {e}"}

    result["diskPath"] = str(vm_disk)
    return result


@mcp.tool()
def start_vm(name: str) -> dict:
    """
    Start a VM. Spawns vm-helper as a detached background process because
    Virtualization.framework's RunLoop must run for the lifetime of the VM.
    Returns once the VM has started (or failed to start).

    Args:
        name: VM name.
    """
    proc = subprocess.Popen(
        [str(BINARY), "start", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,  # detach so the VM outlives the MCP server
    )

    # Wait up to 3 seconds for an immediate failure (e.g. entitlement error).
    # Use select() so the deadline actually fires — readline() alone blocks forever.
    # If still running after 3s, the VM is booting; caller should poll vm_status.
    deadline = time.time() + 3
    buf = ""
    while time.time() < deadline:
        remaining = max(0, deadline - time.time())
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if ready:
            line = proc.stdout.readline()
            if line:
                buf += line
                try:
                    return json.loads(buf)
                except json.JSONDecodeError:
                    pass
        if proc.poll() is not None:
            buf += proc.stdout.read()
            try:
                return json.loads(buf)
            except json.JSONDecodeError:
                return {"success": False, "error": proc.stderr.read().strip() or buf.strip()}

    return {"success": True, "message": f"VM '{name}' is booting. Poll vm_status until state is 'running'."}


@mcp.tool()
def stop_vm(name: str) -> dict:
    """
    Stop a running VM (sends SIGTERM to the vm-helper process).

    Args:
        name: VM name.
    """
    return _run_helper("stop", name)


@mcp.tool()
def delete_vm(name: str) -> dict:
    """
    Delete a VM and all its files. The VM must be stopped first.

    Args:
        name: VM name.
    """
    return _run_helper("delete", name)


@mcp.tool()
def vm_status(name: str) -> dict:
    """
    Get detailed status of a VM (state, memory, CPU, disk/iso paths).

    Args:
        name: VM name.
    """
    return _run_helper("status", name)


@mcp.tool()
def run_command_in_vm(name: str, command: str, timeout: int = 60) -> dict:
    """
    Run a shell command inside a running VM via the virtio serial console.

    Commands are sent to the VM by writing to a named FIFO and output is
    read back from a second FIFO. Requires the VM to be running with
    autologin enabled on hvc0 (configured by cloud-init via seed.iso).

    Use timeout=120 for the first command after start_vm — cloud-init on
    first boot can take 60–90 seconds.

    Args:
        name: VM name.
        command: Shell command to run inside the VM.
        timeout: Seconds to wait. Default 60; use 120+ right after start_vm.
    """
    input_pipe  = VM_BASE_DIR / name / "serial-input"
    output_pipe = VM_BASE_DIR / name / "serial-output"

    if not input_pipe.exists() or not output_pipe.exists():
        return {
            "success": False,
            "error": f"Serial pipes not found — is VM '{name}' running?",
        }

    wrapped = f"{command}; echo '{SENTINEL}'$?\n"

    try:
        # O_NONBLOCK prevents blocking if the VM serial reader isn't ready yet.
        # ENXIO (errno 6) means no reader — VM still booting, caller should retry.
        fd = os.open(str(input_pipe), os.O_WRONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "w") as fin:
            fin.write(wrapped)
    except OSError as e:
        import errno
        if e.errno == errno.ENXIO:
            return {"success": False, "error": "VM serial console not ready yet — retry in a few seconds"}
        return {"success": False, "error": f"Failed to write to serial input: {e}"}

    output_lines: list[str] = []
    deadline = time.time() + timeout

    try:
        # O_NONBLOCK so the open itself doesn't block; select() drives reads.
        fd_out = os.open(str(output_pipe), os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd_out, "r") as fout:
            partial = ""
            while time.time() < deadline:
                remaining = max(0.05, deadline - time.time())
                ready, _, _ = select.select([fout], [], [], min(1.0, remaining))
                if not ready:
                    continue
                chunk = fout.read(4096)
                if not chunk:
                    time.sleep(0.05)
                    continue
                partial += chunk
                while "\n" in partial:
                    line, partial = partial.split("\n", 1)
                    line += "\n"
                    if line.startswith(SENTINEL):
                        exit_code_str = line.strip().removeprefix(SENTINEL)
                        exit_code = int(exit_code_str) if exit_code_str.isdigit() else 0
                        return {
                            "success": exit_code == 0,
                            "stdout": "".join(output_lines),
                            "exit_code": exit_code,
                        }
                    output_lines.append(line)
    except OSError as e:
        return {"success": False, "error": f"Failed to read from serial output: {e}"}

    return {"success": False, "error": f"Command timed out after {timeout}s"}


if __name__ == "__main__":
    mcp.run()
