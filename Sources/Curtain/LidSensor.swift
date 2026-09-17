import Foundation
import IOKit.hid

@MainActor
final class LidSensor {
    private var device: IOHIDDevice?

    var isClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    func read() -> Double? {
        if device == nil { connect() }
        guard let device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard result == kIOReturnSuccess, length >= 3 else {
            disconnect()
            return nil
        }
        let angle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        return (0...180).contains(angle) ? angle : nil
    }

    private func connect() {
        // Enumerate the sensor directly. Opening the whole HID manager can
        // request access to input devices that Curtain does not need.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let usage = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            if page?.intValue == 0x20, usage?.intValue == 0x8A {
                let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service)
                IOObjectRelease(service)
                if let candidate, IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess { device = candidate }
                return
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    func disconnect() {
        if let device { IOHIDDeviceClose(device, 0) }
        device = nil
    }
}
