import Foundation

// MARK: - VM State

enum VMState: String, Codable {
    case stopped
    case running
}

// MARK: - Config Struct

struct VMConfig: Codable {
    var name: String
    var isoPath: String        // path to bootable ISO (used on first boot only)
    var diskPath: String       // path to the VM's main disk image
    var memoryMB: UInt64
    var cpuCount: Int
    var state: VMState

    // Set after first boot by reading from the VM console output
    // Not used for networking (NAT), but useful for status display
    var firstBootComplete: Bool

    init(
        name: String,
        isoPath: String,
        diskPath: String,
        memoryMB: UInt64 = 2048,
        cpuCount: Int = 2
    ) {
        self.name             = name
        self.isoPath          = isoPath
        self.diskPath         = diskPath
        self.memoryMB         = memoryMB
        self.cpuCount         = cpuCount
        self.state            = .stopped
        self.firstBootComplete = false
    }
}

// MARK: - Directory Helpers

/// ~/.vm-mcp/vms/
func vmBaseDir() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir  = home
        .appendingPathComponent(".vm-mcp")
        .appendingPathComponent("vms")
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    return dir
}

/// ~/.vm-mcp/vms/<name>/
func vmDir(name: String) -> URL {
    vmBaseDir().appendingPathComponent(name)
}

/// ~/.vm-mcp/vms/<name>/config.json
func vmConfigPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("config.json")
}

/// ~/.vm-mcp/vms/<name>/disk.img
func vmDiskPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("disk.img")
}

/// ~/.vm-mcp/vms/<name>/efivars.fd
func vmEFIVarsPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("efivars.fd")
}

/// ~/.vm-mcp/vms/<name>/vm.pid
func vmPIDPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("vm.pid")
}

/// ~/.vm-mcp/vms/<name>/console.log
func vmConsolePath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("console.log")
}

/// ~/.vm-mcp/vms/<name>/serial-input  (named pipe, host writes → VM reads)
func vmSerialInputPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("serial-input")
}

/// ~/.vm-mcp/vms/<name>/serial-output  (named pipe, VM writes → host reads)
func vmSerialOutputPath(name: String) -> URL {
    vmDir(name: name).appendingPathComponent("serial-output")
}

// MARK: - Config I/O

func loadConfig(name: String) throws -> VMConfig {
    let data = try Data(contentsOf: vmConfigPath(name: name))
    return try JSONDecoder().decode(VMConfig.self, from: data)
}

func saveConfig(_ config: VMConfig) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(config)
    try data.write(to: vmConfigPath(name: config.name))
}

// MARK: - PID Helpers

func writePID(_ pid: Int32, name: String) throws {
    let data = "\(pid)".data(using: .utf8)!
    try data.write(to: vmPIDPath(name: name))
}

func readPID(name: String) -> Int32? {
    guard let data = try? Data(contentsOf: vmPIDPath(name: name)),
          let str  = String(data: data, encoding: .utf8),
          let pid  = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return pid
}

func isProcessRunning(pid: Int32) -> Bool {
    // kill with signal 0 just checks if the process exists
    return kill(pid, 0) == 0
}

func clearPID(name: String) {
    try? FileManager.default.removeItem(at: vmPIDPath(name: name))
}

// MARK: - Name Validation

func validateVMName(_ name: String) -> String? {
    guard !name.isEmpty else { return "VM name cannot be empty" }
    guard name.count <= 64 else { return "VM name must be 64 characters or fewer" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return "VM name may only contain letters, numbers, hyphens, and underscores"
    }
    return nil  // nil = valid
}

// MARK: - JSON Output

func printJSON(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict, options: .prettyPrinted),
          let str = String(data: data, encoding: .utf8)
    else {
        print(#"{"success": false, "error": "Failed to serialize response"}"#)
        return
    }
    print(str)
}

func succeed(_ message: String, extra: [String: Any] = [:]) {
    var dict: [String: Any] = ["success": true, "message": message]
    dict.merge(extra) { _, new in new }
    printJSON(dict)
}

func fail(_ message: String) {
    printJSON(["success": false, "error": message])
}
