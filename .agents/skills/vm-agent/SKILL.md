---
name: vm-agent
description: "Create, start, stop, delete, and run shell commands inside ARM64 Linux VMs on macOS Apple Silicon. Use whenever the user mentions VMs, virtual machines, spinning up Linux, or running commands in an isolated environment. Do NOT use for Docker containers, cloud VMs (AWS/GCP/Azure), or non-virtualization tasks."
---

# vm-agent skill

Manages macOS virtual machines via Apple's Virtualization.framework.
Invoke it by running:

    vm-agent "<natural language instruction>"

## What it can do

- List all VMs and their state
- Create a VM (clones Ubuntu 22.04 ARM64 disk instantly via APFS)
- Start / stop / delete a VM
- Run shell commands inside a running VM and return stdout + exit code

## How to use it as a sub-agent

vm-agent is a black box. Give it a complete natural-language task and it
returns a natural-language result. That is the entire interface.

**Do NOT:**
- Call MCP tools (list_vms, vm_status, run_command_in_vm, etc.) directly
- Inspect internal VM fields such as firstBootComplete, state, or diskPath
- Poll status yourself or try to sequence individual steps
- Probe the VM in any way before or after calling vm-agent

Raw VM state (MCP tool output, firstBootComplete, JSON fields) is only for
explicit user-requested debugging. Never inspect it autonomously.

**Do:**
- Delegate the entire task in one instruction
- Read the natural-language response vm-agent returns
- Call vm-agent again if a follow-up task is needed

vm-agent handles all sequencing internally: boot detection, status polling,
cloud-init wait, command execution, and error recovery. You will never need
to look at raw VM state.

**Examples:**

    vm-agent "list my VMs"
    vm-agent "create a VM called demo and start it"
    vm-agent "start the demo VM, run uname -a and free -h, then stop it"
    vm-agent "delete the demo VM"

## Important caveats

- First boot takes ~2 minutes (cloud-init runs once). Subsequent starts ~10s.
- VMs require macOS 13+ on Apple Silicon.
- Commands run via virtio serial console — no SSH or network config needed.
