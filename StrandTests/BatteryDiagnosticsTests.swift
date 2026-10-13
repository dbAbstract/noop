import XCTest
@testable import Strand

final class BatteryDiagnosticsTests: XCTestCase {
    private func fixture(now: Int = 1000) -> (UserDefaults, BatteryDiagnostics) {
        let defaults = UserDefaults(suiteName: "BatteryDiagnosticsTests.\(UUID())")!
        return (defaults, BatteryDiagnostics(defaults: defaults, now: now))
    }

    func testDurationsTrafficAndPersistenceExcludeProcessGap() {
        let (defaults, tracker) = fixture()
        defer { defaults.removeObject(forKey: BatteryDiagnostics.storageKey) }
        tracker.note(.connection(true), device: "private-strap-address", now: 1000)
        tracker.note(.write(command: "other", realtime: true), device: "private-strap-address", now: 1001)
        tracker.note(.syncStart, device: "private-strap-address", now: 1010)
        tracker.note(.received(bytes: 100, standardHr: true), device: "private-strap-address", now: 1020)
        tracker.note(.syncEnd(reason: "HISTORY_COMPLETE", rows: 500), device: "private-strap-address", now: 1040)
        tracker.note(.battery(pct: 35, charging: false, policy: "hourly; continuous"), device: "private-strap-address", now: 1600)
        let text = tracker.exportLines(now: 1600).joined(separator: "\n")
        XCTAssertTrue(text.contains("connected_wall_seconds=600"))
        XCTAssertTrue(text.contains("realtime_requested_wall_seconds=599"))
        XCTAssertTrue(text.contains("sync_wall_seconds=30"))
        XCTAssertTrue(text.contains("sync_rows=500"))
        XCTAssertTrue(text.contains("rx_bytes=100"))
        XCTAssertTrue(text.contains("soc_read_t=1600"))
        XCTAssertFalse(text.contains("private-strap-address"))
        tracker.flushForTesting()
        let restored = BatteryDiagnostics(defaults: defaults, now: 9000)
        let after = restored.exportLines(now: 9600).joined(separator: "\n")
        XCTAssertTrue(after.contains("connected_wall_seconds=600"), "Do not account the unobserved terminated-process gap")
        XCTAssertTrue(after.contains("soc=35.00"))
    }

    func testNoPerNotificationCheckpointAndRetainsTwoWeekBound() {
        let (defaults, tracker) = fixture()
        defer { defaults.removeObject(forKey: BatteryDiagnostics.storageKey) }
        for now in 1000..<1600 {
            tracker.note(.received(bytes: 10, standardHr: false), device: "strap", now: now)
        }
        var text = tracker.exportLines(now: 1600).joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "battery-checkpoint").count - 1, 1)
        XCTAssertTrue(text.contains("rx_updates=600"))
        tracker.note(.battery(pct: 15, charging: false, policy: "hourly"), device: "strap", now: 1600)
        text = tracker.exportLines(now: 1600).joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "battery-checkpoint").count - 1, 2)
        let future = 1600 + BatteryDiagnostics.retentionSeconds + 1
        tracker.note(.battery(pct: 90, charging: true, policy: "hourly"), device: "strap", now: future)
        text = tracker.exportLines(now: future).joined(separator: "\n")
        XCTAssertFalse(text.contains("soc=15.00"))
        tracker.clear(); tracker.flushForTesting()
        XCTAssertNil(defaults.data(forKey: BatteryDiagnostics.storageKey))
    }

    func testChargingEdgesDoNotInventNewBatteryReadings() {
        let (defaults, tracker) = fixture()
        defer { defaults.removeObject(forKey: BatteryDiagnostics.storageKey) }
        tracker.note(.battery(pct: 35, charging: false, policy: "hourly"), device: "strap", now: 1000)
        tracker.note(.charging(true), device: "strap", now: 1100)
        let text = tracker.exportLines(now: 1100).joined(separator: "\n")
        XCTAssertTrue(text.contains("soc_read_t=1000 charging=true"))
        XCTAssertFalse(text.contains("soc_read_t=1100"))
        XCTAssertTrue(text.contains("battery_readings=1"))
    }
    func testIdentityAssociationDoesNotInventAReconnectOrKeepOldTimerRunning() {
        let (defaults, tracker) = fixture()
        defer { defaults.removeObject(forKey: BatteryDiagnostics.storageKey) }
        tracker.note(.connection(true), device: "old-registry-id", now: 1000)
        tracker.note(.association(false), device: "old-registry-id", now: 1100)
        tracker.note(.association(true), device: "canonical-registry-id", now: 1100)
        tracker.note(.write(command: "heavy_realtime_on", realtime: nil), device: "canonical-registry-id", now: 1100)
        let text = tracker.exportLines(now: 1700).joined(separator: "\n")
        let current = text.components(separatedBy: "\n").filter { $0.contains(" current:") }
        XCTAssertEqual(current.count, 2)
        XCTAssertTrue(current.contains { $0.contains("connected_wall_seconds=100") && $0.contains("connects=1") })
        XCTAssertTrue(current.contains { $0.contains("connected_wall_seconds=600") && !$0.contains("connects=") })
        XCTAssertTrue(text.contains("heavy_requested_wall_seconds=600"))
    }

}
