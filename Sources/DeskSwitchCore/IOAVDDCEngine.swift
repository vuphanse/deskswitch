import Foundation
import IOKit

/// Runtime bindings for the Apple Silicon display service I2C API. These symbols are
/// exported by the system but not declared in public headers; resolve via dlsym like
/// m1ddc does. If resolution fails the engine refuses to construct.
private struct IOAVSymbols {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias CopyEDIDFn = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    typealias ReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    let createWithService: CreateWithServiceFn
    let copyEDID: CopyEDIDFn
    let readI2C: ReadI2CFn
    let writeI2C: WriteI2CFn

    static func load() -> IOAVSymbols? {
        let handle = dlopen(nil, RTLD_NOW)
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let edid = dlsym(handle, "IOAVServiceCopyEDID"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return IOAVSymbols(
            createWithService: unsafeBitCast(create, to: CreateWithServiceFn.self),
            copyEDID: unsafeBitCast(edid, to: CopyEDIDFn.self),
            readI2C: unsafeBitCast(read, to: ReadI2CFn.self),
            writeI2C: unsafeBitCast(write, to: WriteI2CFn.self))
    }
}

public final class IOAVDDCEngine: DDCEngine {
    public enum EngineError: Error, CustomStringConvertible {
        case symbolsUnavailable
        case displayNotFound(String)
        case i2cError(String)
        case badReply(String)

        public var description: String {
            switch self {
            case .symbolsUnavailable:
                return "IOAVService symbols unavailable (Apple Silicon required)"
            case .displayNotFound(let n):
                return "display '\(n)' is not driven by this Mac"
            case .i2cError(let d):
                return "I2C transfer failed: \(d)"
            case .badReply(let d):
                return "unparseable DDC reply: \(d)"
            }
        }
    }

    // DDC/CI over I2C: chip address 0x37, data/register address 0x51.
    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let symbols: IOAVSymbols
    private var services: [String: AnyObject] = [:]
    // The HTTP server queue and the UI's background refresh share one engine instance;
    // discover() mutates the cache, so every public entry point serializes on this lock.
    private let lock = NSLock()

    public init() throws {
        guard let s = IOAVSymbols.load() else { throw EngineError.symbolsUnavailable }
        symbols = s
    }

    /// Finds external displays: DCPAVServiceProxy registry entries with Location=External,
    /// keyed by EDID product name. Called before every operation — never trust a stale
    /// snapshot, because monitors attach/detach at runtime as they switch between Macs.
    private func discover() {
        services.removeAll()
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let location = IORegistryEntryCreateCFProperty(
                    service, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  location == "External",
                  let av = symbols.createWithService(kCFAllocatorDefault, service)?
                    .takeRetainedValue() else { continue }
            var edidRef: Unmanaged<CFData>?
            guard symbols.copyEDID(av, &edidRef) == KERN_SUCCESS,
                  let edid = edidRef?.takeRetainedValue() as Data? else { continue }
            if let name = edidDisplayName(edid) {
                services[name] = av
            }
        }
    }

    public func connectedDisplayNames() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        discover()
        return Array(services.keys).sorted()
    }

    /// Rediscovers, then resolves — a monitor that just appeared (pull flow) or vanished
    /// (peer pushed it away) is seen without restarting the agent.
    private func service(for displayName: String) throws -> AnyObject {
        discover()
        guard let av = services[displayName] else {
            throw EngineError.displayNotFound(displayName)
        }
        return av
    }

    public func readInput(displayName: String) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let av = try service(for: displayName)
        var request = DDC.readVCPRequestPacket(code: DDC.inputSelect)
        guard symbols.writeI2C(av, Self.chipAddress, Self.dataAddress,
                               &request, UInt32(request.count)) == KERN_SUCCESS else {
            throw EngineError.i2cError("read request to \(displayName)")
        }
        usleep(50_000)  // DDC/CI requires ≥40 ms between request and reply
        var reply = [UInt8](repeating: 0, count: 12)
        guard symbols.readI2C(av, Self.chipAddress, Self.dataAddress,
                              &reply, UInt32(reply.count)) == KERN_SUCCESS else {
            throw EngineError.i2cError("reply read from \(displayName)")
        }
        guard let value = DDC.parseVCPReply(reply, expectedCode: DDC.inputSelect) else {
            throw EngineError.badReply(reply.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        return value
    }

    public func setInput(displayName: String, code: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        let av = try service(for: displayName)
        var packet = DDC.setVCPPacket(code: DDC.inputSelect, value: code)
        // Spec: retry once on failure. No read-back verification: a successful push
        // detaches the display from this Mac, so absence afterwards is success.
        for attempt in 0..<2 {
            if symbols.writeI2C(av, Self.chipAddress, Self.dataAddress,
                                &packet, UInt32(packet.count)) == KERN_SUCCESS {
                return
            }
            if attempt == 0 { usleep(100_000) }
        }
        throw EngineError.i2cError("set input on \(displayName)")
    }
}
