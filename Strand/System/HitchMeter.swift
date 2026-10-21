import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Counts dropped frames on the Coach screen, by what was happening, so "it feels slow" becomes numbers a
/// Coach export carries (`AICoachEngine.conversationExport`, `perf.*` keys).
///
/// FORK-LOCAL. Runs only while the Coach screen is on screen, on the display link the screen is drawn by
/// anyway; nothing leaves the device except inside an export the user shares. A frame counts as a hitch
/// when it took more than 1.5× the display's frame time, and its excess over one frame is the hitch time —
/// the same measure Instruments' hitch tool reports. iOS only: macOS 13 has no view-independent display
/// link, so there the meter stays empty.
@MainActor
final class HitchMeter {
    static let shared = HitchMeter()

    enum Scenario: String, CaseIterable {
        /// The first second after the screen appears.
        case open
        /// A reply streaming in.
        case streaming
        /// Anything else while the screen is up: reading and scrolling the transcript.
        case browsing
        /// The keyboard coming up.
        case keyboard
    }

    struct Stats {
        var frames = 0
        var hitches = 0
        var hitchSeconds = 0.0
        var worstSeconds = 0.0
        var seconds = 0.0
    }

    private(set) var stats: [Scenario: Stats] = [:]
    private var active: Scenario?
    private var lastTimestamp: CFTimeInterval = 0
    private var transient: Task<Void, Never>?
    #if canImport(UIKit)
    private var link: CADisplayLink?
    #endif

    func screenAppeared() {
        switchTo(.open, for: 1.0)
        start()
    }

    func screenDisappeared() {
        stop()
        active = nil
    }

    func streaming(_ on: Bool) {
        if on { transient?.cancel(); switchTo(.streaming) }
        else if active == .streaming { switchTo(.browsing) }
    }

    func keyboardRising() {
        guard active != .streaming else { return }
        switchTo(.keyboard, for: 0.8)
    }

    /// One line per scenario for the export, e.g. "frames 812, hitches 14 (1.7%), hitch 230 ms, worst 96 ms,
    /// over 12.3 s". Empty when nothing was measured.
    var summary: [String: String] {
        var out: [String: String] = [:]
        for scenario in Scenario.allCases {
            guard let s = stats[scenario], s.frames > 0 else { continue }
            let percent = Double(s.hitches) / Double(s.frames) * 100
            out["perf.\(scenario.rawValue)"] = String(format: "frames %d, hitches %d (%.1f%%), hitch %.0f ms, worst %.0f ms, over %.1f s",
                                                      s.frames, s.hitches, percent, s.hitchSeconds * 1000,
                                                      s.worstSeconds * 1000, s.seconds)
        }
        return out
    }

    // MARK: - Internals

    /// Make `scenario` current; after `seconds` (when given) fall back to browsing unless something else
    /// took over meanwhile.
    private func switchTo(_ scenario: Scenario, for seconds: Double? = nil) {
        transient?.cancel()
        active = scenario
        lastTimestamp = 0
        guard let seconds else { return }
        transient = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.active == scenario else { return }
            self.active = .browsing
            self.lastTimestamp = 0
        }
    }

    private func start() {
        #if canImport(UIKit)
        guard link == nil else { return }
        let l = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        #endif
    }

    private func stop() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        #endif
        transient?.cancel()
        lastTimestamp = 0
    }

    #if canImport(UIKit)
    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let scenario = active, lastTimestamp > 0 else { return }
        let frame = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        let elapsed = link.timestamp - lastTimestamp
        // A gap this long is the app in the background or the screen locked (the display link stops), not
        // a frame the screen failed to draw. The first export counted one as a 53-second hitch.
        guard elapsed < 0.5 else { return }
        var s = stats[scenario] ?? Stats()
        s.frames += 1
        s.seconds += elapsed
        if elapsed > frame * 1.5 {
            s.hitches += 1
            s.hitchSeconds += elapsed - frame
            s.worstSeconds = max(s.worstSeconds, elapsed - frame)
        }
        stats[scenario] = s
    }
    #endif
}

#if canImport(UIKit)
/// The display link retains its target; this keeps it from retaining the meter.
private final class DisplayLinkProxy: NSObject {
    weak var meter: HitchMeter?
    init(_ meter: HitchMeter) { self.meter = meter; super.init() }
    @MainActor @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
}
#endif
