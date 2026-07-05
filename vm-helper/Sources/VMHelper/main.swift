import Foundation

// MARK: - Entry Point

guard CommandLine.arguments.count >= 2 else {
    fputs("""
    vm-helper — Apple Virtualization.framework CLI
    Usage: vm-helper <command> [args]

    Commands:
      create <name> <iso_path> [memory_mb] [cpu_count]
      start  <name>
      stop   <name>
      delete <name>
      status <name>
      list

    All output is JSON on stdout.
    """, stderr)
    exit(1)
}

let command = CommandLine.arguments[1]

switch command {

case "create":
    guard CommandLine.arguments.count >= 4 else {
        fail("Usage: create <name> <iso_path> [memory_mb] [cpu_count]"); exit(1)
    }
    let name      = CommandLine.arguments[2]
    let isoPath   = CommandLine.arguments[3]
    let memoryMB  = UInt64(CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "") ?? 2048
    let cpuCount  = Int(CommandLine.arguments.count > 5    ? CommandLine.arguments[5] : "") ?? 2
    createVM(name: name, isoPath: isoPath, memoryMB: memoryMB, cpuCount: cpuCount)

case "start":
    guard CommandLine.arguments.count >= 3 else {
        fail("Usage: start <name>"); exit(1)
    }
    startVM(name: CommandLine.arguments[2])

case "stop":
    guard CommandLine.arguments.count >= 3 else {
        fail("Usage: stop <name>"); exit(1)
    }
    stopVM(name: CommandLine.arguments[2])

case "delete":
    guard CommandLine.arguments.count >= 3 else {
        fail("Usage: delete <name>"); exit(1)
    }
    deleteVM(name: CommandLine.arguments[2])

case "status":
    guard CommandLine.arguments.count >= 3 else {
        fail("Usage: status <name>"); exit(1)
    }
    vmStatus(name: CommandLine.arguments[2])

case "list":
    listVMs()

default:
    fail("Unknown command: '\(command)'")
    exit(1)
}
