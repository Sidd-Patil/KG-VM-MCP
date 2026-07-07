import Foundation
import Virtualization

// MARK: - Start

func startVM(name: String) {
    // Load and validate config
    guard let config = try? loadConfig(name: name) else {
        fail("VM '\(name)' not found"); return
    }

    // Check not already running
    if let pid = readPID(name: name), isProcessRunning(pid: pid) {
        fail("VM '\(name)' is already running (pid \(pid))"); return
    }

    // Build VZVirtualMachineConfiguration
    let vmConfig = VZVirtualMachineConfiguration()
    vmConfig.cpuCount  = config.cpuCount
    vmConfig.memorySize = config.memoryMB * 1024 * 1024

    // ── Boot loader ────────────────────────────────────────────────────────
    let bootLoader  = VZEFIBootLoader()
    let efivarsURL  = vmEFIVarsPath(name: name)
    do {
        if FileManager.default.fileExists(atPath: efivarsURL.path) {
            bootLoader.variableStore = try VZEFIVariableStore(url: efivarsURL)
        } else {
            bootLoader.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: efivarsURL,
                options: []
            )
        }
    } catch {
        fail("EFI variable store error: \(error.localizedDescription)"); return
    }
    vmConfig.bootLoader = bootLoader

    // ── Storage ────────────────────────────────────────────────────────────
    var storageDevices: [VZStorageDeviceConfiguration] = []

    // Main disk (read-write)
    do {
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: config.diskPath), readOnly: false)
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))
    } catch {
        fail("Disk image error: \(error.localizedDescription)"); return
    }

    // ISO — attach on every boot; cloud-init is idempotent after first run
    // and the bootloader will prefer the disk once the OS is installed
    if FileManager.default.fileExists(atPath: config.isoPath) {
        do {
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: config.isoPath), readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
        } catch {
            // Non-fatal: warn but continue — OS may already be installed
            fputs("Warning: could not attach ISO: \(error.localizedDescription)\n", stderr)
        }
    }
    vmConfig.storageDevices = storageDevices

    // ── Network (NAT, no entitlement required) ─────────────────────────────
    let netDevice = VZVirtioNetworkDeviceConfiguration()
    netDevice.attachment = VZNATNetworkDeviceAttachment()
    vmConfig.networkDevices = [netDevice]

    // ── Virtio serial console ──────────────────────────────────────────────
    // We create two named pipes:
    //   serial-input  — host writes commands → VM reads
    //   serial-output — VM writes output → host reads
    //
    // The pipes are created here so the MCP server can open them
    // immediately after start returns.

    let inputPipe  = vmSerialInputPath(name: name).path
    let outputPipe = vmSerialOutputPath(name: name).path

    for pipe in [inputPipe, outputPipe] {
        // Remove stale pipes from a previous run
        if FileManager.default.fileExists(atPath: pipe) {
            try? FileManager.default.removeItem(atPath: pipe)
        }
        guard mkfifo(pipe, 0o600) == 0 else {
            fail("Failed to create named pipe at \(pipe): \(String(cString: strerror(errno)))"); return
        }
    }

    // Open pipes — O_RDWR on a FIFO avoids blocking waiting for the other end
    guard let inputFD  = FileHandle(forUpdatingAtPath: inputPipe),
          let outputFD = FileHandle(forUpdatingAtPath: outputPipe)
    else {
        fail("Failed to open serial named pipes"); return
    }

    let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
    // VM reads from inputFD, writes to outputFD
    serialPort.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: inputFD,
        fileHandleForWriting: outputFD
    )
    vmConfig.serialPorts = [serialPort]

    // ── Extra devices ──────────────────────────────────────────────────────
    vmConfig.entropyDevices       = [VZVirtioEntropyDeviceConfiguration()]
    vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    // ── Validate ───────────────────────────────────────────────────────────
    do {
        try vmConfig.validate()
    } catch {
        fail("VM configuration invalid: \(error.localizedDescription)"); return
    }

    // ── Update config state ────────────────────────────────────────────────
    var updatedConfig = config
    updatedConfig.state = .running
    try? saveConfig(updatedConfig)

    // ── Write our own PID so stop can find us ──────────────────────────────
    try? writePID(ProcessInfo.processInfo.processIdentifier, name: name)

    // ── Start VM ───────────────────────────────────────────────────────────
    let vm       = VZVirtualMachine(configuration: vmConfig)
    let delegate = VMDelegate(name: name)
    vm.delegate  = delegate

    vm.start { result in
        switch result {
        case .success:
            succeed("VM '\(name)' started", extra: [
                "serialInput":  inputPipe,
                "serialOutput": outputPipe,
                "consolePath":  vmConsolePath(name: name).path
            ])
            // Do NOT exit — RunLoop keeps the VM alive
        case .failure(let error):
            fail("Failed to start VM: \(error.localizedDescription)")
            exit(1)
        }
    }

    // Intercept SIGTERM so Virtualization.framework can cleanly tear down
    // the XPC hypervisor service before this process exits. Without this,
    // the XPC process lingers in memory after stopVM sends SIGTERM.
    signal(SIGTERM, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigSource.setEventHandler {
        vm.stop { _ in
            delegate.markStopped()
            exit(0)
        }
    }
    sigSource.resume()

    // RunLoop is required — Virtualization.framework callbacks run on main thread
    RunLoop.main.run()
}

// MARK: - Stop

func stopVM(name: String) {
    guard FileManager.default.fileExists(atPath: vmDir(name: name).path) else {
        fail("VM '\(name)' not found"); return
    }

    guard let pid = readPID(name: name) else {
        fail("No PID file for VM '\(name)' — is it running?"); return
    }

    guard isProcessRunning(pid: pid) else {
        // Stale PID — clean up and report stopped
        clearPID(name: name)
        if var config = try? loadConfig(name: name) {
            config.state = .stopped
            try? saveConfig(config)
        }
        fail("VM '\(name)' process (pid \(pid)) is not running"); return
    }

    // SIGTERM → clean shutdown; VM delegate will handle the rest
    kill(pid, SIGTERM)

    // Update config state immediately (the background process updates it too,
    // but the host process may check before that happens)
    if var config = try? loadConfig(name: name) {
        config.state = .stopped
        try? saveConfig(config)
    }
    clearPID(name: name)

    succeed("VM '\(name)' stopped")
}

// MARK: - VM Delegate

/// Handles async VM lifecycle events from Virtualization.framework.
/// Runs in the background start process (not the MCP server process).
class VMDelegate: NSObject, VZVirtualMachineDelegate {
    let name: String

    init(name: String) {
        self.name = name
    }

    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        fputs("[vm-helper] VM '\(name)' stopped with error: \(error.localizedDescription)\n", stderr)
        markStopped()
        exit(1)
    }

    func guestDidStop(_ vm: VZVirtualMachine) {
        fputs("[vm-helper] VM '\(name)' guest stopped cleanly.\n", stderr)
        markStopped()
        exit(0)
    }

    func markStopped() {
        clearPID(name: name)
        if var config = try? loadConfig(name: name) {
            config.state = .stopped
            try? saveConfig(config)
        }
        // Clean up named pipes
        try? FileManager.default.removeItem(at: vmSerialInputPath(name: name))
        try? FileManager.default.removeItem(at: vmSerialOutputPath(name: name))
    }
}
