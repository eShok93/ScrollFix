// Read-only I/O Registry snapshot. This never opens a HID device or reads reports.
// Run: swift -module-cache-path /private/tmp/scrollfix-hid-swift-cache scripts/hid-inventory-probe.swift
// Run model checks: swift -module-cache-path /private/tmp/scrollfix-hid-swift-cache scripts/hid-inventory-probe.swift --self-test

import Foundation
import IOKit
import IOKit.hid

private struct UsagePair: Hashable, CustomStringConvertible {
    let page: Int
    let usage: Int

    var description: String { "\(page):\(usage)" }
}

private struct PointerDevice {
    let registryID: UInt64
    let builtIn: Bool?
    let virtual: Bool?
    let product: String?
    let transport: String?
    let usages: Set<UsagePair>

    var advertisesMouse: Bool {
        usages.contains(UsagePair(page: Int(kHIDPage_GenericDesktop), usage: Int(kHIDUsage_GD_Mouse)))
    }

    var advertisesTouchPad: Bool {
        usages.contains(UsagePair(page: Int(kHIDPage_Digitizer), usage: Int(kHIDUsage_Dig_TouchPad)))
    }
}

private enum InventoryState: Equatable {
    case onlyBuiltInTrackpadInterface
    case externalPointerPresent
    case unknown
}

private func inventoryState(_ devices: [PointerDevice]) -> InventoryState {
    let mice = devices.filter(\.advertisesMouse)
    if mice.contains(where: { $0.builtIn == false }) { return .externalPointerPresent }
    if mice.count == 1 && mice[0].builtIn == true && mice[0].advertisesTouchPad {
        return .onlyBuiltInTrackpadInterface
    }
    return .unknown
}

private func integer(_ raw: Any?) -> Int? {
    (raw as? NSNumber)?.intValue
}

private func usagePairs(_ raw: Any?, primaryPage: Any?, primaryUsage: Any?) -> Set<UsagePair> {
    if let dictionaries = raw as? [[String: Any]], !dictionaries.isEmpty {
        return Set(dictionaries.compactMap { pair in
            guard let page = integer(pair[kIOHIDDeviceUsagePageKey]),
                  let usage = integer(pair[kIOHIDDeviceUsageKey]) else { return nil }
            return UsagePair(page: page, usage: usage)
        })
    }
    guard let page = integer(primaryPage), let usage = integer(primaryUsage) else { return [] }
    return [UsagePair(page: page, usage: usage)]
}

private func property(_ key: String, of service: io_service_t) -> Any? {
    let cfKey = key as CFString
    return IORegistryEntryCreateCFProperty(service, cfKey, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

private func snapshot() throws -> [PointerDevice] {
    var iterator: io_iterator_t = 0
    // Matching dictionary ownership is transferred to IOServiceGetMatchingServices.
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator)
    guard result == KERN_SUCCESS else {
        throw NSError(domain: "HIDInventory", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "IOServiceGetMatchingServices failed: \(result)"])
    }
    defer { IOObjectRelease(iterator) }

    var devices: [PointerDevice] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
        let usages = usagePairs(
            property(kIOHIDDeviceUsagePairsKey, of: service),
            primaryPage: property(kIOHIDPrimaryUsagePageKey, of: service),
            primaryUsage: property(kIOHIDPrimaryUsageKey, of: service)
        )
        let device = PointerDevice(
            registryID: registryID,
            builtIn: property(kIOHIDBuiltInKey, of: service) as? Bool,
            virtual: property(kIOHIDVirtualHIDevice, of: service) as? Bool,
            product: property(kIOHIDProductKey, of: service) as? String,
            transport: property(kIOHIDTransportKey, of: service) as? String,
            usages: usages
        )
        if device.advertisesMouse { devices.append(device) }
    }
    return devices.sorted { $0.registryID < $1.registryID }
}

private func selfTest() {
    func device(_ id: UInt64, _ builtIn: Bool?, _ pairs: Set<UsagePair>) -> PointerDevice {
        PointerDevice(registryID: id, builtIn: builtIn, virtual: nil, product: nil, transport: nil, usages: pairs)
    }
    let mouse = UsagePair(page: 1, usage: 2)
    let touchPad = UsagePair(page: 13, usage: 5)
    let keyboard = UsagePair(page: 1, usage: 6)
    precondition(usagePairs([[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
                             [kIOHIDDeviceUsagePageKey: 13, kIOHIDDeviceUsageKey: 5]],
                            primaryPage: nil, primaryUsage: nil) == [mouse, touchPad])
    precondition(usagePairs(nil, primaryPage: 1, primaryUsage: 2) == [mouse])
    precondition(inventoryState([device(1, true, [mouse, touchPad])]) == .onlyBuiltInTrackpadInterface)
    precondition(inventoryState([device(1, true, [mouse])]) == .unknown)
    precondition(inventoryState([device(1, true, [mouse, touchPad]), device(2, false, [mouse])]) == .externalPointerPresent)
    precondition(inventoryState([device(1, true, [mouse, touchPad]), device(2, nil, [mouse])]) == .unknown)
    precondition(inventoryState([device(1, true, [keyboard])]) == .unknown)
    print("HID inventory model: 7 checks passed")
}

if CommandLine.arguments.dropFirst() == ["--self-test"] {
    selfTest()
} else {
    do {
        let devices = try snapshot()
        print("Registered HID Generic Desktop / Mouse interfaces: \(devices.count)")
        for device in devices {
            let builtIn = device.builtIn.map { $0 ? "yes" : "no" } ?? "unknown"
            let virtual = device.virtual.map { $0 ? "yes" : "no" } ?? "absent"
            let product = device.product ?? "unknown"
            let transport = device.transport ?? "unknown"
            let usages = device.usages.map(\.description).sorted().joined(separator: ",")
            print("0x\(String(device.registryID, radix: 16)) built-in=\(builtIn) virtual=\(virtual) touchpad=\(device.advertisesTouchPad) transport=\(transport) product=\(product) usages=\(usages)")
        }
        print("state=\(inventoryState(devices))")
    } catch {
        fputs("HID inventory failed: \(error)\n", stderr)
        exit(1)
    }
}
