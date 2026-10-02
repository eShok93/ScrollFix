import CoreGraphics
import Foundation

struct MouseWheelConfiguration: Equatable, Sendable {
    var feel: MouseWheelFeel = .native
    var canPost = false
    var minimumStep: Int64 = MouseWheelMotion.minimumStep
    var effectiveFeel: MouseWheelFeel { feel.requiresPosting && !canPost ? .native : feel }
}

struct MouseWheelSample: Equatable, Sendable {
    let lineDelta: Int64
    let pointDelta: Int64
    let rawDelta: Double
    let gapMilliseconds: Double?
    let plannedDistance: Int64?
    let immediateDistance: Int64?
    let feel: MouseWheelFeel
    let denseInput: Bool
}

/// Owned entirely by the event-tap run-loop thread. Templates never cross to the UI.
/// Trackpad, momentum, ambiguous pixel input and modified scrolling bypass this stage.
final class MouseWheelPipeline {
    private(set) var configuration = MouseWheelConfiguration()
    private var motion = MouseWheelMotion()
    private var smoothMotion = SmoothWheelMotion()
    private var cadence = WheelInputCadence()
    private var template: CGEvent?
    private var lastWheelAt: UInt64?
    private(set) var samples: [MouseWheelSample] = []
    private let collectDiagnostics: Bool
    private(set) var postedFrames: UInt64 = 0
    private(set) var maxTickGapNanoseconds: UInt64 = 0
    private var lastTickAt: UInt64?
    private var frameSource: CGEventSource?

    init(collectDiagnostics: Bool = false) { self.collectDiagnostics = collectDiagnostics }

    var isActive: Bool { motion.isActive || smoothMotion.isActive }

    func configure(_ value: MouseWheelConfiguration) {
        var checked = value
        checked.minimumStep = max(16, min(128, checked.minimumStep))
        guard configuration != checked else { return }
        cancel()
        configuration = checked
        if checked.effectiveFeel.requiresPosting, frameSource == nil {
            // Prepare after positive posting access, before the first wheel input.
            frameSource = CGEventSource(stateID: .combinedSessionState)
            frameSource?.localEventsSuppressionInterval = 0
        }
    }

    func cancel(clearDiagnostics: Bool = false) {
        motion.cancel()
        smoothMotion.cancel()
        cadence.cancel()
        template = nil
        lastTickAt = nil
        if clearDiagnostics {
            samples.removeAll(keepingCapacity: true)
            lastWheelAt = nil
            postedFrames = 0
            maxTickGapNanoseconds = 0
        }
    }

    /// Called after the direction rewrite. It returns the same event object;
    /// the tap does not gain ownership of a newly allocated return value.
    func process(_ event: CGEvent, source: ScrollSourceClassifier.Source?, at now: UInt64,
                 canAnimate: Bool = true) -> CGEvent? {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == ScrollFixSyntheticEvent.wheelSmoothMarker { return event }
        if marker == ScrollFixSyntheticEvent.autoScrollMarker { cancel(); return event }
        guard source == .mouseWheel,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else {
            cancel()
            return event
        }
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        guard event.flags.intersection(modifiers).isEmpty,
              event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0,
              event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0,
              event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0,
              event.getDoubleValueField(.scrollWheelEventRawDeltaAxis2) == 0,
              event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis2) == 0,
              event.getIntegerValueField(.scrollWheelEventDeltaAxis3) == 0,
              event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0,
              event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3) == 0 else {
            cancel()
            return event
        }
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let raw = event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)
        let accelerated = event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let effective = configuration.effectiveFeel
        let feel = effective.requiresPosting && !canAnimate ? .native : effective
        guard fixed.isFinite, abs(fixed) <= Double(MouseWheelMotion.maximumInput),
              raw.isFinite, abs(raw) <= Double(MouseWheelMotion.maximumInput),
              accelerated.isFinite, abs(accelerated) <= Double(MouseWheelMotion.maximumInput),
              event.location.x.isFinite, event.location.y.isFinite,
              let nativeDistance = MouseWheelMotion.normalizedDistance(pointDelta: point, lineDelta: line,
                                                                      minimumStep: configuration.minimumStep,
                                                                      applyMinimum: false),
              line == 0 || point == 0 || (line < 0) == (point < 0) else {
            cancel()
            return event
        }
        let gap = lastWheelAt.flatMap { now >= $0 ? Double(now - $0) / 1_000_000 : nil }
        lastWheelAt = now
        if feel == .native {
            cancel()
            record(.init(lineDelta: line, pointDelta: point, rawDelta: raw, gapMilliseconds: gap,
                         plannedDistance: nil, immediateDistance: nil, feel: .native, denseInput: false))
            return event
        }
        if let previous = template, !Self.sameContext(previous, event) { cancel() }
        if feel.requiresPosting, frameSource == nil { cancel(); return event }
        let input = cadence.observe(distance: nativeDistance, at: now)
        // Dense input stays proportional. The first opposite impulse retains
        // the minimum distance so counter-steering starts visibly on a frame.
        let applyMinimum = feel != .smooth || !input.isDense || input.reversed
        guard let distance = MouseWheelMotion.normalizedDistance(
            pointDelta: point, lineDelta: line, minimumStep: configuration.minimumStep,
            applyMinimum: applyMinimum
        ) else { cancel(); return event }
        let immediate: Int64
        if feel == .smooth {
            guard let candidate = event.copy(), let accepted = smoothMotion.add(
                distance: distance, at: now, responsive: input.isDense || input.reversed,
                startsNewGesture: input.startsNewGesture
            ) else {
                cancel()
                return event
            }
            template = candidate
            record(.init(lineDelta: line, pointDelta: point, rawDelta: raw, gapMilliseconds: gap,
                         plannedDistance: accepted, immediateDistance: 0, feel: feel, denseInput: input.isDense))
            // The entire impulse joins the continuous response. Only a display
            // pulse emits movement, so new wheel input cannot add an initial jump.
            return nil
        } else if feel == .tactile {
            guard let candidate = event.copy(), let amount = motion.add(distance: distance, at: now) else {
                cancel()
                return event
            }
            template = candidate
            immediate = amount
        } else {
            cancel()
            immediate = distance
        }
        guard let frame = Self.makeFrame(pixels: immediate, template: event, source: frameSource) else {
            cancel()
            return event
        }
        Self.applyVerticalFrame(frame, to: event)
        record(.init(lineDelta: line, pointDelta: point, rawDelta: raw, gapMilliseconds: gap,
                     plannedDistance: distance, immediateDistance: immediate, feel: feel, denseInput: false))
        return event
    }

    /// Does not post: the worker owns posting and checks tap state immediately before it.
    func nextFrame(at now: UInt64) -> CGEvent? {
        guard configuration.effectiveFeel.requiresPosting, let original = template else { return nil }
        if let previous = lastTickAt, now >= previous {
            maxTickGapNanoseconds = max(maxTickGapNanoseconds, now - previous)
        }
        lastTickAt = now
        let pixels = configuration.effectiveFeel == .smooth
            ? smoothMotion.advance(at: now) : motion.advance(at: now)
        if !isActive { template = nil; lastTickAt = nil }
        guard pixels != 0 else { return nil }
        return Self.makeFrame(pixels: pixels, template: original, deferred: true, source: frameSource)
    }

    func recordPostedFrame() { if collectDiagnostics { postedFrames &+= 1 } }

    private func record(_ sample: MouseWheelSample) {
        guard collectDiagnostics else { return }
        if samples.count == 16 { samples.removeFirst() }
        samples.append(sample)
    }

    private static func sameContext(_ lhs: CGEvent, _ rhs: CGEvent) -> Bool {
        lhs.location == rhs.location && lhs.flags == rhs.flags
            && lhs.getIntegerValueField(.eventTargetUnixProcessID) == rhs.getIntegerValueField(.eventTargetUnixProcessID)
    }

    static func makeFrame(pixels: Int64, template: CGEvent, deferred: Bool = false,
                          source: CGEventSource? = nil) -> CGEvent? {
        guard pixels >= Int64(Int32.min), pixels <= Int64(Int32.max),
              let frame = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(pixels), wheel2: 0, wheel3: 0) else { return nil }
        frame.flags = template.flags
        frame.location = template.location
        frame.timestamp = deferred ? DispatchTime.now().uptimeNanoseconds : template.timestamp
        frame.setIntegerValueField(.eventTargetUnixProcessID,
                                  value: template.getIntegerValueField(.eventTargetUnixProcessID))
        frame.setIntegerValueField(.eventSourceUserData, value: ScrollFixSyntheticEvent.wheelSmoothMarker)
        return frame
    }

    private static func applyVerticalFrame(_ frame: CGEvent, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                  value: frame.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                  value: frame.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                 value: frame.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollFixSyntheticEvent.wheelSmoothMarker)
    }
}
