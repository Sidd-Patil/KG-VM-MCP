from pathlib import Path

from google.adk.agents import LlmAgent
from google.adk.apps import App
from google.adk.tools.mcp_tool.mcp_toolset import (
    MCPToolset,
    StdioConnectionParams,
    StdioServerParameters,
)

_MCP_SERVER = Path(__file__).parent.parent / "mcp_server" / "server.py"

SYSTEM_PROMPT = """
You are a VM management assistant controlling macOS virtual machines via
Apple's Virtualization.framework.

You have these tools: list_vms, create_vm, start_vm, stop_vm, delete_vm,
vm_status, run_command_in_vm.

Always check vm_status before running commands. When asked to set something
up, do it step by step and report each result. If a command fails, show the
error and suggest a fix.

VMs use NAT networking (internet access, not host-reachable by IP).
Commands run via virtio serial console — no SSH needed.
Use timeout=120 for the first run_command_in_vm call after start_vm,
since cloud-init on first boot takes 60-90 seconds.
""".strip()

root_agent = LlmAgent(
    model="gemini-2.0-flash",
    name="vm_agent",
    instruction=SYSTEM_PROMPT,
    tools=[
        MCPToolset(
            connection_params=StdioConnectionParams(
                server_params=StdioServerParameters(
                    command="python",
                    args=[str(_MCP_SERVER)],
                )
            )
        )
    ],
)

app = App(root_agent=root_agent, name="agent")
