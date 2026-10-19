import XCTest
import StrandAnalytics
import WhoopStore
import WhoopProtocol
@testable import Strand

/// The diet budget's workout pricing end to end over an in-memory store: a strap-recorded session is
/// re-priced from its own trace, a session belongs to the day it started, confirming played time rewrites
/// the stored figure, and an import is left as it stored itself.
@MainActor
final class DietWorkoutEnergyTests: XCTestCase {

    private let deviceId = "diet-energy-test"
    private let body = DietBody(sex: "male", weightKg: 72.8, heightCm: 174, age: 27, hrMax: 189)

    private func makeRepo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    private func row(start: Int, minutes: Int, sport: String, source: String = "manual",
                     kcal: Double?) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: source,
                   durationS: Double(minutes * 60), energyKcal: kcal, avgHr: 140, maxHr: 170, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func todayAt(hour: Int, minute: Int = 0) -> Int {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        return Int(midnight.timeIntervalSince1970) + hour * 3_600 + minute * 60
    }

    private func heartRate(_ bpm: Int, from start: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// A 30-minute ride at 140 bpm, stored at 400 kcal by the old model: the budget prices the trace and
    /// carries the stored figure beside it.
    func testAStrapRecordedRowIsRepricedFromItsTrace() async throws {
        let (repo, store) = try await makeRepo()
        let start = todayAt(hour: 7)
        _ = try await store.insert(Streams(hr: heartRate(140, from: start, seconds: 1_800)), deviceId: deviceId)
        let ride = row(start: start, minutes: 30, sport: "Cycling", kcal: 400)
        _ = try await store.upsertWorkouts([ride], deviceId: deviceId)

        let credit = await repo.workoutCredit(for: ride, body: body)
        let expected = try XCTUnwrap(SportEnergy.estimate(
            samples: heartRate(140, from: start, seconds: 1_800), startTs: ride.startTs, endTs: ride.endTs,
            profile: WorkoutEnergyProfile(body: body).userProfile, hrmax: 189, restingHR: nil,
            sport: "Cycling", offMask: nil))
        let b = try XCTUnwrap(credit.breakdown)
        XCTAssertEqual(b.grossKcal, expected.grossKcal, accuracy: 0.001)
        XCTAssertEqual(credit.credit.recordedKcal, 400, "the stored figure is reported unchanged")
        XCTAssertEqual(credit.credit.pricedKcal, expected.grossKcal, accuracy: 0.001)
        XCTAssertEqual(credit.credit.creditedKcal, expected.grossKcal - body.bmrKcalPerDay / 86_400 * 1_800,
                       accuracy: 0.01)
        XCTAssertTrue(credit.credit.isRepriced)
        XCTAssertLessThan(credit.credit.pricedKcal, 400, "the old model ran high at this heart rate")
        XCTAssertTrue(b.inputs.restingHRWasDefaulted, "no scored day, so the card must say resting was assumed")
    }

    /// A session from 23:30 to 00:30 is credited to the day it started, once — not in full to both days.
    func testASessionCrossingMidnightCountsOnItsStartDayOnly() async throws {
        let (repo, store) = try await makeRepo()
        let start = todayAt(hour: 0) - 30 * 60
        let late = row(start: start, minutes: 60, sport: "Cycling", kcal: 500)
        _ = try await store.upsertWorkouts([late], deviceId: deviceId)

        let today = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(todayAt(hour: 12))))
        let yesterday = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        let onToday = await repo.workoutCreditsForDay(today, body: body)
        let onYesterday = await repo.workoutCreditsForDay(yesterday, body: body)
        XCTAssertTrue(onToday.isEmpty)
        XCTAssertEqual(onYesterday.map(\.row.startTs), [start])
    }

    /// A futsal block, 10 min playing (fast, moving) then 10 min on the bench (heart still up, still): the
    /// budget applies the strap's split before anyone confirms; confirming then writes the trace's figure
    /// into the stored row.
    func testConfirmingPlayedTimeRewritesTheStoredFigure() async throws {
        let (repo, store) = try await makeRepo()
        let start = todayAt(hour: 9)
        let hr = heartRate(165, from: start, seconds: 600) + heartRate(130, from: start + 600, seconds: 600)
        let gravity = (0..<1_200).map { s in
            GravitySample(ts: start + s, x: 0, y: 0, z: 1, dynAccel: s < 600 ? 0.8 : 0.05)
        }
        _ = try await store.insert(Streams(hr: hr, gravity: gravity), deviceId: deviceId)
        let futsal = row(start: start, minutes: 20, sport: "Futsal", kcal: 300)
        _ = try await store.upsertWorkouts([futsal], deviceId: deviceId)

        let before = await repo.workoutCredit(for: futsal, body: body)
        let unconfirmed = try XCTUnwrap(before.breakdown)
        XCTAssertEqual(unconfirmed.maskSource, .motionThreshold)
        XCTAssertGreaterThan(unconfirmed.offMinutes, 0, "the bench is priced as bench before any confirm")
        XCTAssertEqual(before.trace?.suggestedPlayedSeconds ?? 0, Double(unconfirmed.onMinutes * 60))

        let ok = await repo.setConfirmedPlayedSeconds(600, for: futsal, body: body)
        XCTAssertTrue(ok)
        let stored = try await store.workouts(deviceId: deviceId, from: start - 1, to: start + 1, limit: 10)
        let rewritten = try XCTUnwrap(stored.first(where: { $0.startTs == start })?.energyKcal)
        let expected = try XCTUnwrap(before.trace?.breakdown(playedS: 600).grossKcal)
        XCTAssertEqual(rewritten, expected, accuracy: 0.001)

        let after = await repo.workoutCredit(for: futsal, body: body)
        XCTAssertTrue(after.isPlayedTimeConfirmed)
        XCTAssertEqual(after.breakdown?.maskSource, .confirmedPlayedTime)
        XCTAssertEqual(after.breakdown?.onMinutes, 10)
    }

    /// An Apple Health workout carries Apple's own active figure: no trace, no re-pricing.
    func testAnImportIsLeftAsItStoredItself() async throws {
        let (repo, store) = try await makeRepo()
        let start = todayAt(hour: 6)
        _ = try await store.insert(Streams(hr: heartRate(150, from: start, seconds: 1_800)), deviceId: deviceId)
        let apple = row(start: start, minutes: 30, sport: "Cycling", source: "apple-health", kcal: 250)
        _ = try await store.upsertWorkouts([apple], deviceId: "apple-health")

        let credit = await repo.workoutCredit(for: apple, body: body)
        XCTAssertNil(credit.trace)
        XCTAssertNil(credit.breakdown)
        XCTAssertFalse(credit.credit.isRepriced)
        XCTAssertEqual(credit.credit.creditedKcal, 250, "active-only energy passes through")
    }
}
