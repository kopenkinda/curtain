import Foundation
import IOKit.ps

struct BatteryStatus {
    let percentage: Int
    let onBattery: Bool

    func reached(_ limit: Int) -> Bool { limit > 0 && onBattery && percentage <= limit }

    static func read() -> BatteryStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let power = values[kIOPSPowerSourceStateKey] as? String else { continue }
            return BatteryStatus(percentage: min(100, max(0, current * 100 / maximum)), onBattery: power == kIOPSBatteryPowerValue)
        }
        return nil
    }
}
