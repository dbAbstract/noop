import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

// MARK: - The one place a strap-recorded workout is priced
//
// FORK-LOCAL (Apple). Four readers want a workout's energy: the live save, the post-sync rescore, the diet
// budget and the detail screen's "how this was estimated" card. If each read the trace and resolved the
// profile by itself, the card could print a figure the budget would not then produce, which is the
// two-readouts-of-one-fact failure AGENTS.md names. So every one of them goes through `workoutEnergyTrace`,
// and what they get back is a LEDGER rather than a number: the heart-rate evidence folded per minute,
// independent of any played-time decision. Pricing the ledger for a given played time is then a pure fold
// (`WorkoutEnergyTrace.breakdown`), which is what lets a coach card quote the figure the budget will then
// show without a second read of the store.

/// The body and HRmax a workout is priced with — a value, so a reader without the environment object (the
/// coach, the rescore) prices from the same figures the screen does.
struct WorkoutEnergyProfile: Equatable {
    let sex: String
    let weightKg: Double
    let heightCm: Double
    let age: Double
    let hrMax: Double

    init(sex: String, weightKg: Double, heightCm: Double, age: Double, hrMax: Double) {
        self.sex = sex; self.weightKg = weightKg; self.heightCm = heightCm; self.age = age; self.hrMax = hrMax
    }

    @MainActor init(_ profile: ProfileStore) {
        self.init(sex: profile.sex, weightKg: profile.weightKg, heightCm: profile.heightCm,
                  age: Double(profile.age), hrMax: Double(profile.hrMax))
    }

    init(body: DietBody) {
        self.init(sex: body.sex, weightKg: body.weightKg, heightCm: body.heightCm, age: body.age, hrMax: body.hrMax)
    }

    var userProfile: UserProfile {
        UserProfile(weightKg: weightKg, heightCm: heightCm, age: age, sex: sex)
    }

    /// `UserProfile.cacheKey` carries no HRmax, and HRmax moves every figure here.
    var cacheKey: String { userProfile.cacheKey + ",hm=\(hrMax.bitPattern)" }
}

/// A workout's priced evidence: the per-minute ledger, the inputs it was folded with, and the strap's
/// per-minute motion when it recorded any.
struct WorkoutEnergyTrace: Equatable {
    let ledger: SportEnergy.Ledger
    let inputs: SportEnergy.Inputs
    /// Smoothed per-minute motion (`PlayedTimeEstimate.minuteActivity`), or nil when the strap recorded none
    /// usable: a WHOOP 4.0, a dropout, or a session whose motion has not been offloaded yet.
    let minuteActivity: [Double?]?

    /// Price the session for a played time: nil applies the strap's own split (when there is one), a value
    /// marks the most-active minutes up to it as played. A steady sport ignores the mask either way.
    func breakdown(playedS: Double?) -> SportEnergy.Breakdown {
        let mask = PlayedTimeEstimate.offMask(minuteActivity: minuteActivity, playedS: playedS)
        let source: SportEnergy.MaskSource = mask == nil ? .none : (playedS == nil ? .motionThreshold : .confirmedPlayedTime)
        return SportEnergy.price(ledger, inputs: inputs, offMask: mask, maskSource: source)
    }

    /// The strap's own split in seconds, or nil without usable motion — what the confirm control offers.
    var suggestedPlayedSeconds: Double? {
        guard let mask = PlayedTimeEstimate.offMask(minuteActivity: minuteActivity, playedS: nil) else { return nil }
        return min(ledger.durationS, Double(mask.filter { !$0 }.count * 60))
    }
}

extension Repository {

    /// True for a row whose energy the app itself priced from the strap: a live/manual session or a legacy
    /// detected bout. Imports (WHOOP, Apple Health, files) carry their vendor's figure and are never re-priced.
    nonisolated static func isStrapRecorded(_ source: String) -> Bool {
        switch WorkoutSource.classify(source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }

    /// THE resting HR a workout is priced against: the newest scored day at or before the workout's own day
    /// that has one, else today's, else nil (the model then defaults to 60 and says so). The live save, the
    /// rescore and the budget all resolve it here, so a session cannot be scored against one resting HR and
    /// re-priced against another.
    func restingHR(forWorkoutStartingAt ts: Int) -> Double? {
        let dayKey = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts)))
        if let row = days.last(where: { $0.day <= dayKey && $0.restingHr != nil }), let rhr = row.restingHr {
            return Double(rhr)
        }
        return today?.restingHr.map(Double.init)
    }

    /// The funnel. Reads the workout's own HR (the detail screen's id resolver, so the card and the HR curve
    /// above it describe the same strap; an explicit limit, because the day-union default of 8,000 cuts a
    /// session off after ~2 h 13 min at 1 Hz) and the strap's motion, folds them, and memoises the result
    /// until the next refresh. nil for an import or a window with under two readings.
    ///
    /// `hrOverride` is the live save's own captured window, used before the strap has offloaded anything;
    /// a trace built from it is not memoised, since the offload will replace it.
    func workoutEnergyTrace(for row: WorkoutRow, profile: WorkoutEnergyProfile,
                            hrOverride: [HRSample]? = nil) async -> WorkoutEnergyTrace? {
        guard Self.isStrapRecorded(row.source), row.endTs > row.startTs else { return nil }
        let restingHR = restingHR(forWorkoutStartingAt: row.startTs)
        // A refresh can land HR or motion for any window, so the whole memo is dropped when it moves rather
        // than keyed on it — keying would keep every superseded trace alive for the session.
        if workoutEnergyMemoSeq != refreshSeq {
            workoutEnergyMemo.removeAll()
            workoutEnergyMemoSeq = refreshSeq
        }
        let key = "\(row.source)|\(row.startTs)|\(row.endTs)|\(row.sport)|\(profile.cacheKey)|rhr=\(restingHR ?? -1)"
        if hrOverride == nil, let hit = workoutEnergyMemo[key] { return hit }

        let inputs = SportEnergy.inputs(profile: profile.userProfile, hrmax: profile.hrMax,
                                        restingHR: restingHR, sport: row.sport)
        let samples: [HRSample]
        if let hrOverride {
            samples = hrOverride
        } else {
            let ids = Self.workoutHrDeviceIds(source: row.source, activeStrapId: deviceId, importedIds: importedReadIds)
            samples = await hrSamples(deviceIds: ids, from: row.startTs, to: row.endTs, limit: 200_000)
        }
        guard let ledger = SportEnergy.ledger(samples: samples, startTs: row.startTs, endTs: row.endTs,
                                              inputs: inputs) else { return nil }
        var activity: [Double?]?
        if inputs.traits.offMET != nil {
            let motion = await gravitySamplesUnion(from: row.startTs, to: row.endTs - 1)
                .compactMap { s in s.dynAccel.map { (ts: s.ts, dynAccel: $0) } }
            activity = PlayedTimeEstimate.minuteActivity(samples: motion, startTs: row.startTs, endTs: row.endTs)
        }
        let trace = WorkoutEnergyTrace(ledger: ledger, inputs: inputs, minuteActivity: activity)
        // Only if no refresh landed during the reads above; otherwise this trace may already be stale.
        if hrOverride == nil, workoutEnergyMemoSeq == refreshSeq { workoutEnergyMemo[key] = trace }
        return trace
    }

    /// Trace + price in one call, for a caller that only wants the figure.
    func workoutEnergy(for row: WorkoutRow, playedS: Double?,
                       profile: WorkoutEnergyProfile) async -> SportEnergy.Breakdown? {
        await workoutEnergyTrace(for: row, profile: profile)?.breakdown(playedS: playedS)
    }
}
