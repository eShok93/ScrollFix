import CoreGraphics

@main
struct ScrollFixSelfCheck {
    static func main() {
        let mayBegin = Int64(CGScrollPhase.mayBegin.rawValue)
        let began = Int64(CGScrollPhase.began.rawValue)
        let changed = Int64(CGScrollPhase.changed.rawValue)
        let ended = Int64(CGScrollPhase.ended.rawValue)
        let momentumBegin = Int64(CGMomentumScrollPhase.begin.rawValue)
        let momentumContinue: Int64 = 2 // kCGMomentumScrollPhaseContinue

        var source = ScrollSourceClassifier()
        precondition(source.classify(scrollPhase: 0, momentumPhase: 0, at: 1).source == .mouseWheel)
        precondition(source.classify(scrollPhase: began, momentumPhase: 0, at: 2).source == .unknown)
        source.reset()
        precondition(source.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 10).source == .trackpad)
        precondition(source.classify(scrollPhase: began, momentumPhase: 0, at: 11).source == .trackpad)
        precondition(source.classify(scrollPhase: ended, momentumPhase: 0, at: 12).source == .trackpad)
        precondition(source.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 13).source == .trackpad)
        precondition(source.classify(scrollPhase: 0, momentumPhase: 0, at: 14).source == .mouseWheel)
        precondition(source.classify(scrollPhase: 0, momentumPhase: momentumContinue, at: 15).source == .trackpad)
        source.reset()
        precondition(source.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1).source == .trackpad)
        precondition(source.classify(scrollPhase: 0, momentumPhase: 0, at: 2).source == .mouseWheel)
        precondition(source.classify(scrollPhase: began, momentumPhase: 0, at: 3_000_000_000).source == .trackpad)
        source.reset()
        precondition(source.classify(scrollPhase: changed, momentumPhase: 0, at: 2_000_000_000).source == .unknown)
        source.reset()
        _ = source.classify(scrollPhase: mayBegin, momentumPhase: 0, at: 1)
        _ = source.classify(scrollPhase: began, momentumPhase: 0, at: 2)
        _ = source.classify(scrollPhase: ended, momentumPhase: 0, at: 3)
        precondition(source.classify(scrollPhase: 0, momentumPhase: momentumBegin, at: 2_000_000_000).source == .unknown)

        var physics = AutoScrollPhysics()
        precondition(physics.tick(offset: CGVector(dx: 0, dy: 22)) == .init(vertical: 2, horizontal: 0))
        precondition(physics.tick(offset: CGVector(dx: 22, dy: 0)) == .init(vertical: 0, horizontal: -2))
        precondition(physics.tick(offset: CGVector(dx: CGFloat.nan, dy: 0)) == nil)
        precondition(physics.tick(offset: CGVector(dx: 0, dy: 10_000), speed: 3) == .init(vertical: 240, horizontal: 0))
        var regular = AutoScrollPhysics()
        var delayed = AutoScrollPhysics()
        let regularPixels = (0..<60).reduce(0) { total, _ in
            total + Int(regular.tick(offset: CGVector(dx: 0, dy: 22), elapsedSeconds: 0.016)?.vertical ?? 0)
        }
        let delayedPixels = (0..<30).reduce(0) { total, _ in
            total + Int(delayed.tick(offset: CGVector(dx: 0, dy: 22), elapsedSeconds: 0.032)?.vertical ?? 0)
        }
        precondition(regularPixels == 120 && delayedPixels == regularPixels)
        precondition(physics.tick(offset: CGVector(dx: 0, dy: 22), elapsedSeconds: 0.25) == .init(vertical: 5, horizontal: 0))
        precondition(physics.tick(offset: CGVector(dx: 0, dy: 22), elapsedSeconds: .nan) == nil)
        print("ScrollFix classifier and autoscroll physics self-check passed")
    }
}
