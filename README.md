# vm-mcp

Control macOS virtual machines with a single natural-language prompt.

```
vm-agent "create a VM called dev and install nginx"
```

---

## Problem

Spinning up a macOS VM for local development requires juggling multiple tools: a hypervisor, disk image preparation, cloud-init configuration, serial console access, and lifecycle management. There is no unified interface — you drop into shell scripts and manual steps every time.

The goal: replace all of that with one command driven by natural language, backed by Apple's native Virtualization.framework.

---

## Solution

`vm-mcp` is an AI agent that manages macOS VMs end-to-end. A Gemini-powered ADK agent accepts natural-language instructions, reasons about what needs to happen, and calls structured tools to carry it out. Those tools talk to a Swift binary that uses Apple's Virtualization.framework directly — no QEMU, no Docker, no third-party hypervisor.

```
you ──▶ vm-agent "..." ──▶ ADK Agent ──▶ MCP Server ──▶ VMHelper (Swift) ──▶ VMs
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  User                                                   │
│  vm-agent "create a VM called dev and install nginx"    │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  ADK Agent  (agent/agent.py)                            │
│  • Gemini model (gemini-flash-lite-latest)              │
│  • Reasons over goal, decides which tools to call       │
│  • Packaged as an Agents CLI skill                      │
└───────────────────────┬─────────────────────────────────┘
                        │  MCP protocol (stdio)
                        ▼
┌─────────────────────────────────────────────────────────┐
│  MCP Server  (mcp_server/server.py)                     │
│  Tools:                                                 │
│    list_vms       vm_status      create_vm              │
│    start_vm       stop_vm        delete_vm              │
│    run_command_in_vm                                    │
└───────────────────────┬─────────────────────────────────┘
                        │  subprocess
                        ▼
┌─────────────────────────────────────────────────────────┐
│  VMHelper  (vm-helper/  — Swift)                        │
│  • Apple Virtualization.framework                       │
│  • EFI boot, virtio block, NAT network, serial console  │
│  • Named FIFOs for serial I/O (serial-input/output)     │
│  • Each VM: independent disk copy, PID file, config     │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
              macOS Hypervisor (XPC)
              Ubuntu 22.04 ARM64 VMs
```

### Key design decisions

- **Serial console over SSH** — commands run via a virtio serial port mapped to named FIFOs. No network configuration or SSH key management needed.
- **Sentinel pattern** — `run_command_in_vm` appends `; echo '__VM_DONE__'$?` to every command and reads until the sentinel appears, making command completion detection reliable.
- **APFS cloning** — `cp -c` gives each new VM its own copy-on-write disk clone in milliseconds instead of copying 2.5 GB.
- **Non-blocking I/O** — all FIFO reads use `select()` with deadlines so the MCP server never hangs waiting for VM output.
- **Clean shutdown** — the VMHelper start process intercepts SIGTERM and calls `vm.stop()` before exiting, ensuring the Virtualization.framework XPC service is torn down rather than orphaned.
- **cloud-init** — a seed ISO configures the Ubuntu image on first boot: autologin on `hvc0`, passwordless sudo, serial getty enabled.

---

## Project Structure

```
vm-mcp/
├── agent/
│   ├── agent.py          # ADK LlmAgent + MCPToolset
│   ├── skill.py          # CLI entrypoint (vm-agent command)
│   └── __init__.py
├── mcp_server/
│   └── server.py         # FastMCP server — 7 VM management tools
├── vm-helper/            # Swift package
│   └── Sources/VMHelper/
│       ├── main.swift        # CLI routing
│       ├── VMConfig.swift    # Config struct, path helpers
│       ├── VMLifecycle.swift # create, delete, list, status
│       └── VMRunner.swift    # start, stop (Virtualization.framework)
├── scripts/
│   └── prepare_image.sh  # Download Ubuntu image + build seed ISO
├── agents-cli-manifest.yaml
├── Dockerfile
├── pyproject.toml
└── tests/
```

---

## Setup

### Prerequisites

- macOS 13+ on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.11+
- Swift 5.9+ (`swift --version`)
- `qemu-img` (`brew install qemu`)
- A Gemini API key from [Google AI Studio](https://aistudio.google.com)

### 1. Install Python dependencies

```bash
pip install -e .
```

### 2. Configure API key

```bash
echo "GOOGLE_API_KEY=your_key_here" > agent/.env
```

### 3. Prepare the Ubuntu disk image

Downloads Ubuntu 22.04 ARM64, converts to raw format, and builds the cloud-init seed ISO (~600 MB download, ~2.5 GB after conversion):

```bash
bash scripts/prepare_image.sh
```

### 4. Build the Swift binary

```bash
swift build -c release --package-path vm-helper
```

### 5. Sign the binary

Apple's Virtualization.framework requires the `com.apple.security.virtualization` entitlement:

```bash
cat > /tmp/entitlements.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
EOF

codesign --sign - --entitlements /tmp/entitlements.plist --force \
    vm-helper/.build/release/VMHelper
```

---

## Usage

### CLI

```bash
# Natural-language prompt — agent handles everything
vm-agent "create a VM called dev and install nginx"

# Simpler tasks
vm-agent "list my VMs"
vm-agent "start the dev VM"
vm-agent "run uname -a in the dev VM"
vm-agent "stop the dev VM"
```

### Web UI (Agents CLI)

```bash
adk web
```

Opens a browser-based chat interface backed by the same agent and tools.

---

## Security

- **API key** — stored in `agent/.env`, excluded from git via `.gitignore`. Never committed.
- **OS-enforced entitlement** — `com.apple.security.virtualization` must be granted at signing time; arbitrary processes cannot call Virtualization.framework.
- **VM isolation** — each VM gets its own independent disk copy; VMs cannot share filesystem state.
- **No inbound network** — VMs use NAT networking. They have outbound internet access but are not reachable from the host by IP.
