import XCTest
@testable import Strand

/// The strap-log lines for iOS's MetricKit reports say only what iOS reported, in words a person can read.
final class MetricKitLineTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let begin = Date(timeIntervalSince1970: 1_790_035_200)   // 2026-09-22 00:00 UTC

    func testADayReadsAsOneLine() {
        var day = MetricKitLine.Day(begin: begin, end: begin.addingTimeInterval(86_400), appVersion: "11.8.0")
        day.foreground = 4_320
        day.background = 34_800
        day.cpu = 372
        day.peakMemoryBytes = 180 * 1_048_576
        day.diskWriteBytes = 1_536 * 1_048_576
        day.hangs = 3
        day.exits = [.init(reason: "normal", count: 4), .init(reason: "CPU limit", count: 1),
                     .init(reason: "crash", count: 0)]
        XCTAssertEqual(MetricKitLine.day(day, timeZone: utc),
                       "MetricKit day 2026-09-22 00:00 → 2026-09-23 00:00 (NOOP 11.8.0): foreground 1h 12m, "
                       + "background 9h 40m, CPU 6m 12s, peak memory 180 MB, disk writes 1.5 GB, hangs 3, "
                       + "exits: normal 4, CPU limit 1")
    }

    /// A field MetricKit left out is left out of the line — never printed as a zero it did not report.
    func testWhatIOSDidNotReportIsNotPrinted() {
        let day = MetricKitLine.Day(begin: begin, end: begin.addingTimeInterval(86_400), appVersion: "11.8.0")
        XCTAssertEqual(MetricKitLine.day(day, timeZone: utc),
                       "MetricKit day 2026-09-22 00:00 → 2026-09-23 00:00 (NOOP 11.8.0): exits: none")
    }

    func testADiagnosticNamesItsKind() {
        XCTAssertEqual(MetricKitLine.diagnostic("CPU exception", appVersion: "11.8.0", at: begin,
                                                detail: "48s of CPU in 1m 0s", timeZone: utc),
                       "MetricKit CPU exception (NOOP 11.8.0, reported 2026-09-22 00:00): 48s of CPU in 1m 0s")
    }

    func testDurationsAndSizes() {
        XCTAssertEqual(MetricKitLine.duration(2.44), "2.4s")
        XCTAssertEqual(MetricKitLine.duration(3), "3s")
        XCTAssertEqual(MetricKitLine.duration(48), "48s")
        XCTAssertEqual(MetricKitLine.duration(372), "6m 12s")
        XCTAssertEqual(MetricKitLine.duration(34_800), "9h 40m")
        XCTAssertEqual(MetricKitLine.duration(.nan), "?")
        XCTAssertEqual(MetricKitLine.bytes(180 * 1_048_576), "180 MB")
        XCTAssertEqual(MetricKitLine.bytes(1_536 * 1_048_576), "1.5 GB")
    }

    // MARK: Call stacks (fork)

    private func frame(_ name: String, _ offset: Int, samples: Int = 1, _ sub: [[String: Any]] = []) -> [String: Any] {
        ["binaryName": name, "binaryUUID": "UUID-\(name)", "offsetIntoBinaryTextSegment": offset,
         "sampleCount": samples, "address": 0, "subFrames": sub]
    }

    private func tree(_ stacks: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["callStackPerThread": true, "callStacks": stacks])
    }

    /// A watchdog kill names the attributed thread, and the main thread (first) when that is another one.
    func testACrashStackNamesTheAttributedThreadAndTheMainThread() {
        let main: [String: Any] = ["threadAttributed": false,
                                   "callStackRootFrames": [frame("NOOP", 0x1a2b, [frame("SwiftUI", 0x40, [frame("UIKitCore", 0x8)])])]]
        let other: [String: Any] = ["threadAttributed": true, "callStackRootFrames": [frame("libsystem_kernel.dylib", 0x10)]]
        XCTAssertEqual(MetricKitLine.stack(tree([main, other])), [
            "MetricKit stack (thread 1, attributed): libsystem_kernel.dylib+0x10",
            "MetricKit stack (thread 0): NOOP+0x1a2b < SwiftUI+0x40 < UIKitCore+0x8",
            "MetricKit binaries: NOOP UUID-NOOP, SwiftUI UUID-SwiftUI, UIKitCore UUID-UIKitCore, "
                + "libsystem_kernel.dylib UUID-libsystem_kernel.dylib",
        ])
    }

    /// An aggregated hang tree branches; the path most samples took is the one that was stuck.
    func testAHangTreeFollowsTheHeaviestPathAndCapsTheFrames() {
        let stack: [String: Any] = ["threadAttributed": true, "callStackRootFrames": [
            frame("NOOP", 1, samples: 2),
            frame("NOOP", 2, samples: 9, [frame("NOOP", 3, samples: 1), frame("GRDB", 4, samples: 8, [frame("libsqlite3.dylib", 5, samples: 8)])]),
        ]]
        XCTAssertEqual(MetricKitLine.stack(tree([stack]), limit: 2).first,
                       "MetricKit stack (thread 0, attributed): NOOP+0x2 < GRDB+0x4 … 1 more")
    }

    func testAnUnreadableTreeAddsNoLines() {
        XCTAssertEqual(MetricKitLine.stack(Data("nope".utf8)), [])
        XCTAssertEqual(MetricKitLine.stack(tree([])), [])
    }
}
