import Foundation
import IOKit
import IOKit.serial

// Wired (USB serial) transport to the clock, for WiFi networks with client
// isolation - or for skipping WiFi setup entirely. Scans for CH340-style and
// native USB CDC serial ports, handshakes, then pushes the same payloads the device would
// otherwise poll over HTTP, as newline-terminated frames:
//   bridge -> device:  #HELLO   #STATUS {json}   #NET {json}   #CMD {json}
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}
// Device log lines (anything not starting with '#') are ignored.
//
// NOTE: the port is opened non-exclusively so esptool/pio can still flash,
// but quit the app before flashing to avoid the two readers fighting.
final class SerialLink {
    private let service: StatusService
    private let netMonitor: NetSpeedMonitor

    private var fd: Int32 = -1
    private var portPath = ""
    private var linked = false // saw #DEVICE from the clock on this port
    private var openedAt = Date.distantPast
    private var lastHelloAt = Date.distantPast
    private var lastStatusAt = Date.distantPast
    private var lastNetAt = Date.distantPast
    private var rxBuf = Data()
    private var timer: Timer?
    private var candidateCursor = 0

    init(service: StatusService, netMonitor: NetSpeedMonitor) {
        self.service = service
        self.netMonitor = netMonitor
    }

    func start() {
        // one 250ms tick drives everything: port scan, handshake, reads, pushes
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    var isLinked: Bool { linked }

    private func tick() {
        if fd < 0 {
            scanAndOpen()
            return
        }
        readPending()
        let now = Date()
        if !linked {
            // handshake: #HELLO every 3s; give up on this port after 30s
            if now.timeIntervalSince(openedAt) > 30 {
                closePort()
                return
            }
            if now.timeIntervalSince(lastHelloAt) > 3 {
                lastHelloAt = now
                send("#HELLO\n".data(using: .utf8)!)
            }
            return
        }
        if now.timeIntervalSince(lastStatusAt) > 5 {
            lastStatusAt = now
            send(frame("#STATUS ", service.snapshot().jsonData()))
        }
        if now.timeIntervalSince(lastNetAt) > 2 {
            lastNetAt = now
            let stats = SystemStatsMonitor.shared.snapshot()
            send(frame("#NET ", netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)))
        }
    }

    private func frame(_ prefix: String, _ json: Data) -> Data {
        var d = Data(prefix.utf8)
        d.append(json) // JSONSerialization output is single-line
        d.append(0x0A)
        return d
    }

    // MARK: - port lifecycle

    private func scanAndOpen() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let nativeEspressifPorts = espressifNativePorts()
        let candidates = names.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") ||
                nativeEspressifPorts.contains("/dev/" + $0)
        }.sorted()
        guard !candidates.isEmpty else {
            candidateCursor = 0
            return
        }
        let start = candidateCursor % candidates.count
        for offset in 0..<candidates.count {
            let index = (start + offset) % candidates.count
            if openPort("/dev/" + candidates[index]) {
                candidateCursor = (index + 1) % candidates.count
                return
            }
        }
        candidateCursor = (start + 1) % candidates.count
    }

    // Native C3 USB Serial/JTAG is fixed at Espressif VID:PID 303A:1001.
    // Restrict the broader cu.usbmodem namespace before sending host telemetry.
    private func espressifNativePorts() -> Set<String> {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ports = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard registryInt(service, key: "idVendor") == 0x303A,
                  registryInt(service, key: "idProduct") == 0x1001,
                  let value = IORegistryEntryCreateCFProperty(
                      service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue() as? String else { continue }
            ports.insert(value)
        }
        return ports
    }

    private func registryInt(_ service: io_registry_entry_t, key: String) -> Int? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options
        ) as? NSNumber else { return nil }
        return value.intValue
    }

    private func openPort(_ path: String) -> Bool {
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return false }
        var tio = termios()
        tcgetattr(f, &tio)
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL) // don't hang-up-reset the board on close
        tcsetattr(f, TCSANOW, &tio)
        // Deassert DTR+RTS so the CH340 auto-reset circuit lets the ESP run.
        // TIOCMBIC = _IOW('t', 107, int); TIOCM_DTR|TIOCM_RTS = 0x006.
        var bits: Int32 = 0x006
        _ = ioctl(f, 0x8004_746B, &bits)
        fd = f
        portPath = path
        linked = false
        openedAt = Date()
        lastHelloAt = .distantPast
        rxBuf.removeAll()
        FileHandle.standardError.write(Data("[serial] trying \(path)\n".utf8))
        return true
    }

    private func closePort() {
        if fd >= 0 { close(fd) }
        if linked || fd >= 0 {
            FileHandle.standardError.write(Data("[serial] closed \(portPath)\n".utf8))
        }
        fd = -1
        portPath = ""
        linked = false
    }

    // MARK: - I/O

    private func send(_ data: Data) {
        guard fd >= 0 else { return }
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        if n < 0 && (errno == ENXIO || errno == EIO || errno == EBADF || errno == ENODEV) {
            closePort() // unplugged
        }
    }

    private func readPending() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                rxBuf.append(contentsOf: buf[0..<n])
                if rxBuf.count > 16384 { rxBuf.removeAll() } // runaway noise
                continue
            }
            if n == 0 || (n < 0 && errno != EAGAIN) { closePort() } // EOF / unplugged
            break
        }
        while let nl = rxBuf.firstIndex(of: 0x0A) {
            let lineData = rxBuf.prefix(upTo: nl)
            rxBuf.removeSubrange(...nl)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if line.hasPrefix("#DEVICE") {
                if !linked {
                    linked = true
                    lastStatusAt = .distantPast // push a status immediately
                    lastNetAt = .distantPast
                    FileHandle.standardError.write(Data("[serial] linked \(portPath): \(line)\n".utf8))
                }
            }
            // anything else is the device's debug log - ignore
        }
    }
}
