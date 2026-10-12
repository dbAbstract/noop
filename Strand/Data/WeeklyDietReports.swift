import Foundation
import StrandAnalytics

extension Repository {
    /// Reports are rebuilt from local history, so correcting a past log also corrects its week.
    /// Failure is distinct from an empty history; a failed read must not produce a reassuring report.
    func weeklyDietReports(now: Date = Date()) async throws -> [WeeklyDietReport] {
        guard let store = await storeHandle() else { throw CocoaError(.fileReadUnknown) }
        let to = Self.localDayKey(now)
        func values(_ source: String, _ key: String) async throws -> [Int: Double] {
            let rows = try await store.metricSeries(deviceId: source, key: key, from: "0001-01-01", to: to)
            return Dictionary(rows.compactMap { row in WeeklyDietReview.dayIndex(row.day).map { ($0, row.value) } },
                              uniquingKeysWith: { _, last in last })
        }
        async let intake = values(FoodLogStore.sourceId, FoodLogStore.Keys.caloriesIn)
        async let burn = values(DietStore.sourceId, DietStore.Keys.expenditure)
        async let source = values(DietStore.sourceId, DietStore.Keys.burnSource)
        async let rough = values(FoodLogStore.sourceId, FoodLogStore.Keys.roughDay)
        async let weight = values(WeightLogStore.sourceId, WeightLogStore.key)
        let (i, b, s, r, w) = try await (intake, burn, source, rough, weight)
        let indices = Set(i.keys).union(b.keys).union(w.keys)
        let days = indices.map { day in
            WeeklyDietDay(day: day, intake: i[day], expenditure: b[day], weight: w[day],
                          rough: (r[day] ?? 0) > 0,
                          source: s[day] == 0 ? .formula : s[day] == 1 ? .calibrated : .unknown)
        }
        return WeeklyDietReview.reports(days: days, today: WeeklyDietReview.dayIndex(to)!)
    }
}

extension WeeklyDietReport {
    var startKey: String { WeeklyDietReview.dayKey(startDay) }
    var endKey: String { WeeklyDietReview.dayKey(startDay + 6) }

    /// Exact windows and coverage accompany every figure sent through the existing Coach consent gate.
    var coachContext: String {
        """
        Week \(startKey)...\(endKey) (completed Monday–Sunday; corrected logs update this report):
        Logged intake: \(intakeKcal.map { String($0) } ?? "unknown") kcal on \(intakeDays)/7 days; rough days \(roughDays).
        Estimated expenditure: \(expenditureKcal.map { String($0) } ?? "unknown") kcal on \(expenditureDays)/7 days. Formula source \(formulaDays), intake/weight-calibrated source \(calibratedDays), unknown source \(expenditureDays - formulaDays - calibratedDays).
        Intake minus expenditure on \(pairedDays) matched days ONLY: \(pairedBalanceKcal.map { String($0) } ?? "unknown") kcal. Full-week balance: \(fullWeekBalanceKcal.map { String($0) } ?? "unavailable; missing days are not zero").
        Mean weight: \(meanWeightKg.map { String($0) } ?? "unknown") kg from \(weighInDays) days; weekly averages are descriptive, not proof of fat change.
        Longer weight evidence: \(evidenceStart.map { WeeklyDietReview.dayKey($0) } ?? "unknown")...\(evidenceEnd.map { WeeklyDietReview.dayKey($0) } ?? "unknown"); \(fit?.dayCount ?? 0) weigh-in days. Trend \(fit.map { "\($0.slopeKgPerWeek) ± \($0.weeklyMarginKg) kg/week; scatter \($0.scatterKg) kg" } ?? "unavailable"). Calorie comparison ends BEFORE the last weigh-in; \(evidencePairedDays) matched days; calorie-predicted rate \(expectedKgPerWeek.map { String($0) } ?? "unknown") kg/week. Alignment: \(alignment.rawValue). Uncertainty reason: \(uncertainty?.rawValue ?? "none").
        """
    }
}
