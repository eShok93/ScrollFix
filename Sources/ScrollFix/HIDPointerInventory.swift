import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

/// A device inventory is only a machine-wide hint. CGScrollEvents do not carry
/// the registry ID needed to associate an individual event with a HID device.
enum HIDPointerInventoryState: Equatable {
    case internalTrackpadOnly
    case externalPointerPresent
    case unknown
}

struct HIDPointerRecord: Equatable {
    struct Usage: Hashable {
        let page: Int
        let value: Int
    }

    let registryID: UInt64
    let builtIn: Bool?
    /// `nil` means the property is absent. Absence is not proof of hardware.
    let virtual: Bool?
    let usages: Set<Usage>

    var advertisesMouse: Bool { usages.contains(.init(page: 1, value: 2)) }
    var advertisesPointer: Bool { usages.contains(.init(page: 1, value: 1)) }
    var advertisesTouchPad: Bool { usages.contains(.init(page: 13, value: 5)) }
    var advertisesPointingInterface: Bool {
        advertisesMouse || advertisesPointer || advertisesTouchPad
    }

    static func usages(pairs: Any?, primaryPage: Any?, primaryUsage: Any?) -> Set<Usage> {
        if let pairs = pairs as? [[String: Any]], !pairs.isEmpty {
            return Set(pairs.compactMap { pair in
                guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                      let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue else { return nil }
                return Usage(page: page, value: usage)
            })
        }
        guard let page = (primaryPage as? NSNumber)?.intValue,
              let usage = (primaryUsage as? NSNumber)?.intValue else { return [] }
        return [Usage(page: page, value: usage)]
    }
}

struct HIDPointerInventorySnapshot: Equatable {
    enum Category: Equatable {
        case internalTrackpad
        case externalPointingInterface
        case otherOrUnknown
    }

    let recordsByRegistryID: [UInt64: HIDPointerRecord]

    init(records: [HIDPointerRecord]) {
        recordsByRegistryID = Dictionary(uniqueKeysWithValues: records.map { ($0.registryID, $0) })
    }

    var state: HIDPointerInventoryState {
        HIDPointerInventoryProbe.classify(Array(recordsByRegistryID.values))
    }

    func category(for registryID: UInt64) -> Category? {
        guard let record = recordsByRegistryID[registryID] else { return nil }
        if record.advertisesPointingInterface && record.builtIn == false {
            return .externalPointingInterface
        }
        if record.advertisesMouse && record.advertisesTouchPad &&
            record.builtIn == true && record.virtual != true {
            return .internalTrackpad
        }
        return .otherOrUnknown
    }
}

enum HIDPointerInventoryProbe {
    static func classify(_ records: [HIDPointerRecord]) -> HIDPointerInventoryState {
        let pointers = records.filter(\.advertisesPointingInterface)
        if pointers.contains(where: { $0.builtIn == false }) { return .externalPointerPresent }
        if pointers.count == 1, let pointer = pointers.first,
           pointer.builtIn == true, pointer.virtual != true,
           pointer.advertisesMouse, pointer.advertisesTouchPad {
            return .internalTrackpadOnly
        }
        return .unknown
    }

    static func snapshot() throws -> HIDPointerInventorySnapshot {
        var iterator: io_iterator_t = 0
        // IOKit consumes the matching dictionary. No device is opened.
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator
        )
        guard status == KERN_SUCCESS else {
            throw NSError(domain: "HIDPointerInventory", code: Int(status))
        }
        defer { IOObjectRelease(iterator) }

        var records: [HIDPointerRecord] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else {
                throw NSError(domain: "HIDPointerInventory", code: -1)
            }
            let usages = HIDPointerRecord.usages(
                pairs: property(kIOHIDDeviceUsagePairsKey, service),
                primaryPage: property(kIOHIDPrimaryUsagePageKey, service),
                primaryUsage: property(kIOHIDPrimaryUsageKey, service)
            )
            records.append(.init(
                registryID: id,
                builtIn: property(kIOHIDBuiltInKey, service) as? Bool,
                virtual: property(kIOHIDVirtualHIDevice, service) as? Bool,
                usages: usages
            ))
        }
        return HIDPointerInventorySnapshot(records: records)
    }

    private static func property(_ name: String, _ service: io_service_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            service, name as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
    }
}

/// Registration and enumeration failures should recover without polling IOKit
/// on every UI status update. The status timer checks this deadline; relevant
/// IOKit notifications may still trigger an earlier successful refresh.
struct HIDPointerInventoryRetry {
    static let initialDelay: TimeInterval = 1.5
    static let maximumDelay: TimeInterval = 30

    private(set) var nextAttemptUptime: TimeInterval?
    private(set) var nextDelay = initialDelay

    func isDue(at uptime: TimeInterval) -> Bool {
        guard let nextAttemptUptime else { return false }
        return uptime >= nextAttemptUptime
    }

    mutating func beginAttempt() {
        nextAttemptUptime = nil
    }

    mutating func recordFailure(at uptime: TimeInterval) {
        // A notification during a pending retry must not postpone recovery.
        guard nextAttemptUptime == nil else { return }
        nextAttemptUptime = uptime + nextDelay
        nextDelay = min(nextDelay * 2, Self.maximumDelay)
    }

    mutating func reset() {
        nextAttemptUptime = nil
        nextDelay = Self.initialDelay
    }
}

/// Watches only I/O Registry service registration. It receives no HID reports.
@MainActor
final class HIDPointerInventoryMonitor {
    var onChange: ((HIDPointerInventoryState) -> Void)?
    var onSnapshotChange: ((HIDPointerInventorySnapshot?) -> Void)?
    private(set) var state: HIDPointerInventoryState = .unknown
    private(set) var snapshot: HIDPointerInventorySnapshot?

    private let snapshotProvider: @MainActor () throws -> HIDPointerInventorySnapshot
    private let observeServices: Bool
    private var port: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var arrivalIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0
    private var started = false
    private var retry = HIDPointerInventoryRetry()

    init(
        snapshotProvider: @escaping @MainActor () throws -> HIDPointerInventorySnapshot = HIDPointerInventoryProbe.snapshot,
        observeServices: Bool = true
    ) {
        self.snapshotProvider = snapshotProvider
        self.observeServices = observeServices
    }

    // The IOKit callback uses passUnretained(self), so its source and iterators
    // must be removed before this object can be released.
    isolated deinit {
        tearDownPort()
    }

    func start() {
        started = true
        retry.beginAttempt()
        if !observeServices { refresh(); return }
        if port != nil { refresh(); return }
        guard let newPort = IONotificationPortCreate(kIOMainPortDefault) else {
            recordFailure()
            return
        }
        guard let source = IONotificationPortGetRunLoopSource(newPort)?.takeUnretainedValue() else {
            IONotificationPortDestroy(newPort)
            recordFailure()
            return
        }
        port = newPort
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let arrived = IOServiceAddMatchingNotification(
            newPort, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
            Self.serviceChanged, context, &arrivalIterator
        )
        let removed = IOServiceAddMatchingNotification(
            newPort, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"),
            Self.serviceChanged, context, &removalIterator
        )
        guard arrived == KERN_SUCCESS, removed == KERN_SUCCESS else {
            tearDownPort()
            recordFailure()
            return
        }
        // A notification is armed only after its initial iterator is drained.
        drain(arrivalIterator)
        drain(removalIterator)
        refresh()
    }

    func stop() {
        started = false
        retry.reset()
        tearDownPort()
        publish(nil)
    }

    private func tearDownPort() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if arrivalIterator != 0 { IOObjectRelease(arrivalIterator); arrivalIterator = 0 }
        if removalIterator != 0 { IOObjectRelease(removalIterator); removalIterator = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    func invalidate() { publish(nil) }

    func refresh() {
        refresh(resetPendingRetry: true)
    }

    private func refresh(resetPendingRetry: Bool) {
        guard started else { publish(nil); return }
        // After a failed registration, wake and explicit refresh can rebuild the
        // notification port immediately instead of leaving the state unknown.
        guard port != nil || !observeServices else { start(); return }
        if resetPendingRetry { retry.beginAttempt() }
        do {
            let next = try snapshotProvider()
            retry.reset()
            publish(next)
        } catch {
            recordFailure()
        }
    }

    /// Called by the existing 1.5-second status timer, while the session is active.
    func retryIfNeeded() {
        guard started, retry.isDue(at: ProcessInfo.processInfo.systemUptime) else { return }
        refresh()
    }

    private func recordFailure() {
        // Never keep a stale sole-trackpad result after an IOKit error.
        publish(nil)
        retry.recordFailure(at: ProcessInfo.processInfo.systemUptime)
    }

    private func publish(_ next: HIDPointerInventorySnapshot?) {
        if snapshot != next {
            snapshot = next
            onSnapshotChange?(next)
        }
        let nextState = next?.state ?? .unknown
        guard nextState != state else { return }
        state = nextState
        onChange?(nextState)
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Re-enumerate before publishing a state change. The scroll worker can
    /// briefly see the old snapshot during this read, so refresh immediately
    /// after draining the notification. An IOKit error publishes nil.
    func serviceDidChange() {
        refresh(resetPendingRetry: false)
    }

    private static let serviceChanged: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let monitor = Unmanaged<HIDPointerInventoryMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.drain(iterator)
            // A failed re-enumeration from a noisy device must not repeatedly
            // push the already scheduled recovery attempt into the future.
            monitor.serviceDidChange()
        }
    }
}
