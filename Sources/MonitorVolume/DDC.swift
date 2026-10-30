import Foundation
import IOKit

// Private IOKit SPI used to talk I²C to external displays on Apple Silicon.
typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: IOAVService, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: IOAVService, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// MCCS VCP codes we use.
enum VCP: UInt8 {
    case volume = 0x62
    case mute = 0x8D   // 1 = muted, 2 = unmuted
}

/// A DDC/CI connection to one external display.
///
/// All I²C traffic runs on a private serial queue. Writes are coalesced so that
/// holding a volume key only sends the latest value instead of queueing dozens.
final class DDCDisplay: @unchecked Sendable {
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let hostAddress: UInt8 = 0x6E

    private let service: IOAVService
    private let queue = DispatchQueue(label: "MonitorVolume.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingWrites: [VCP: UInt16] = [:]

    private init(service: IOAVService) {
        self.service = service
    }

    /// Finds the first external display that answers a DDC volume query.
    static func discover() -> DDCDisplay? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            let display = DDCDisplay(service: av)
            if display.readSync(.volume) != nil {
                return display
            }
        }
        return nil
    }

    // MARK: Reading

    func read(_ code: VCP, completion: @escaping @Sendable ((current: UInt16, max: UInt16)?) -> Void) {
        queue.async {
            completion(self.readSync(code))
        }
    }

    private func readSync(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, code.rawValue]
        request.append(checksum(request))

        for _ in 0..<4 {
            guard IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &request, UInt32(request.count)) == kIOReturnSuccess else {
                usleep(20_000)
                continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard IOAVServiceReadI2C(service, Self.chipAddress, Self.dataAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess else {
                continue
            }
            // 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, max)
        }
        return nil
    }

    // MARK: Writing

    func write(_ code: VCP, value: UInt16) {
        lock.withLock { pendingWrites[code] = value }
        queue.async { self.flush() }
    }

    /// Writes immediately and waits for it to finish, e.g. right before the Mac goes to sleep.
    func writeNow(_ code: VCP, value: UInt16) {
        lock.withLock { pendingWrites[code] = value }
        queue.sync { self.flush() }
    }

    private func flush() {
        let writes = lock.withLock {
            defer { pendingWrites.removeAll() }
            return pendingWrites
        }
        for (code, value) in writes {
            var packet: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
            packet.append(checksum(packet))
            // Some monitors drop the first packet; sending twice is harmless.
            for _ in 0..<2 {
                _ = IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &packet, UInt32(packet.count))
                usleep(10_000)
            }
        }
    }

    private func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(Self.hostAddress ^ UInt8(Self.dataAddress), ^)
    }
}
