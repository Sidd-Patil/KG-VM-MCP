import Foundation

// MARK: - Create

func createVM(name: String, isoPath: String, memoryMB: UInt64, cpuCount: Int) {
    // Validate name
    if let error = validateVMName(name) {
        fail(error); return
    }

    // Validate ISO exists
    guard FileManager.default.fileExists(atPath: isoPath) else {
        fail("ISO not found: \(isoPath)"); return
    }

    // Validate resource limits
    guard memoryMB >= 512, memoryMB <= 16384 else {
        fail("memoryMB must be between 512 and 16384"); return
    }
    guard cpuCount >= 1, cpuCount <= 8 else {
        fail("cpuCount must be between 1 and 8"); return
    }

    // Check VM doesn't already exist
    let dir = vmDir(name: name)
    guard !FileManager.default.fileExists(atPath: dir.path) else {
        fail("VM '\(name)' already exists"); return
    }

    // Create VM directory
    do {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    } catch {
        fail("Failed to create VM directory: \(error.localizedDescription)"); return
    }

    // Allocate blank disk image (20 GB sparse file)
    let diskURL  = vmDiskPath(name: name)
    let diskSize = UInt64(20) * 1024 * 1024 * 1024   // 20 GB
    FileManager.default.createFile(atPath: diskURL.path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: diskURL.path) else {
        fail("Failed to open disk image for writing"); return
    }
    do {
        try handle.truncate(atOffset: diskSize)
        handle.closeFile()
    } catch {
        fail("Failed to allocate disk image: \(error.localizedDescription)"); return
    }

    // Write config
    let config = VMConfig(
        name: name,
        isoPath: isoPath,
        diskPath: diskURL.path,
        memoryMB: memoryMB,
        cpuCount: cpuCount
    )
    do {
        try saveConfig(config)
    } catch {
        // Clean up directory if config save fails
        try? FileManager.default.removeItem(at: dir)
        fail("Failed to save VM config: \(error.localizedDescription)"); return
    }

    succeed("VM '\(name)' created", extra: [
        "name":     name,
        "diskPath": diskURL.path,
        "memoryMB": memoryMB,
        "cpuCount": cpuCount
    ])
}

// MARK: - Delete

func deleteVM(name: String) {
    let dir = vmDir(name: name)

    guard FileManager.default.fileExists(atPath: dir.path) else {
        fail("VM '\(name)' not found"); return
    }

    // Refuse to delete a running VM
    if let pid = readPID(name: name), isProcessRunning(pid: pid) {
        fail("VM '\(name)' is running — stop it first"); return
    }

    do {
        try FileManager.default.removeItem(at: dir)
        succeed("VM '\(name)' deleted")
    } catch {
        fail("Failed to delete VM: \(error.localizedDescription)")
    }
}

// MARK: - List

func listVMs() {
    let base  = vmBaseDir()
    let items = (try? FileManager.default.contentsOfDirectory(
        atPath: base.path)) ?? []

    var vms: [[String: Any]] = []
    for item in items.sorted() {
        guard let config = try? loadConfig(name: item) else { continue }

        // Reconcile state: if config says running but PID is dead, mark stopped
        var state = config.state.rawValue
        if config.state == .running {
            if let pid = readPID(name: item), isProcessRunning(pid: pid) {
                state = "running"
            } else {
                state = "stopped (crashed?)"
            }
        }

        vms.append([
            "name":     config.name,
            "state":    state,
            "memoryMB": config.memoryMB,
            "cpuCount": config.cpuCount
        ])
    }

    printJSON(["success": true, "vms": vms])
}

// MARK: - Status

func vmStatus(name: String) {
    guard let config = try? loadConfig(name: name) else {
        fail("VM '\(name)' not found"); return
    }

    var state = config.state.rawValue
    if config.state == .running {
        if let pid = readPID(name: name), isProcessRunning(pid: pid) {
            state = "running"
        } else {
            state = "stopped (crashed?)"
        }
    }

    printJSON([
        "success":          true,
        "name":             config.name,
        "state":            state,
        "memoryMB":         config.memoryMB,
        "cpuCount":         config.cpuCount,
        "firstBootComplete": config.firstBootComplete,
        "diskPath":         config.diskPath,
        "isoPath":          config.isoPath,
        "consolePath":      vmConsolePath(name: name).path
    ])
}
