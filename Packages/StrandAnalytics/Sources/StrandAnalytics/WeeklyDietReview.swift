import Foundation

/// Local calendar-day evidence. Missing intake or expenditure stays unknown, never zero-filled.
public struct WeeklyDietDay: Equatable, Sendable {
    public enum BurnSource: String, Sendable { case formula, calibrated, unknown }
    public let day: Int
    public let intake: Double?
    public let expenditure: Double?
    public let weight: Double?
    public let rough: Bool
    public let source: BurnSource

    public init(day: Int, intake: Double? = nil, expenditure: Double? = nil,
                weight: Double? = nil, rough: Bool = false, source: BurnSource = .unknown) {
        self.day = day
        self.intake = intake.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.expenditure = expenditure.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.weight = weight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.rough = rough
        self.source = source
    }
}

public struct WeeklyDietReport: Equatable, Sendable, Identifiable {
    public enum Alignment: String, Sendable { case consistent, mismatch, uncertain }
    public enum Uncertainty: String, Sendable {
        case insufficientWeight, staleWeight, missingCalories, unknownBurnSource, calibratedBurn, roughEstimates, scatter
    }
    public var id: Int { startDay }
    public let startDay: Int
    public let intakeKcal: Double?
    public let expenditureKcal: Double?
    public let intakeDays: Int
    public let expenditureDays: Int
    public let pairedDays: Int
    public let pairedBalanceKcal: Double?
    public let roughDays: Int
    public let formulaDays: Int
    public let calibratedDays: Int
    public let meanWeightKg: Double?
    public let weighInDays: Int
    public let fit: WeightTrendFit?
    public let evidenceStart: Int?
    public let evidenceEnd: Int?
    public let evidencePairedDays: Int
    public let expectedKgPerWeek: Double?
    public let alignment: Alignment
    public let uncertainty: Uncertainty?

    public var fullWeekBalanceKcal: Double? { pairedDays == 7 ? pairedBalanceKcal : nil }
}

/// Monday–Sunday reports. Civil dates use a UTC calendar solely as an index: timezone offsets and
/// 23/25-hour DST days must never move a local date into another reporting week.
public enum WeeklyDietReview {
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    public static func dayIndex(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let index = Int(floor(date.timeIntervalSince1970 / 86_400))
        return dayKey(index) == key ? index : nil
    }

    public static func dayKey(_ index: Int) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(index) * 86_400))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func monday(containing day: Int) -> Int { day - ((day + 3) % 7 + 7) % 7 }

    public static func reports(days: [WeeklyDietDay], today: Int) -> [WeeklyDietReport] {
        let completed = days.filter { $0.day < monday(containing: today) && ($0.intake != nil || $0.expenditure != nil) }
        guard let first = completed.map(\.day).min() else { return [] }
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
        return stride(from: monday(containing: today) - 7, through: monday(containing: first), by: -7).map { start in
            let week = (start..<start + 7).compactMap { byDay[$0] }
            let intake = week.compactMap(\.intake)
            let burn = week.compactMap(\.expenditure)
            let paired = week.filter { $0.intake != nil && $0.expenditure != nil }
            let weights = week.compactMap(\.weight)
            // Compare calories between observed weigh-ins, through the evening before the last weigh-in.
            // Both sides therefore describe the same interval; no future data enters a past review.
            let readings = (start - 35..<start + 7).compactMap { day -> WeightReading? in
                byDay[day]?.weight.map { WeightReading(dayIndex: day, kg: $0) }
            }
            let fit = WeightTrend.fit(readings)
            let lo = readings.first?.dayIndex
            let hi = readings.last?.dayIndex
            let evidence = lo.flatMap { lower in hi.map { upper in (lower..<upper).compactMap { byDay[$0] } } } ?? []
            let evidencePairs = evidence.filter { $0.intake != nil && $0.expenditure != nil }
            let expected = evidencePairs.isEmpty ? nil : evidencePairs.reduce(0) { $0 + $1.intake! - $1.expenditure! }
                / Double(evidencePairs.count) * 7 / WeightTrend.kcalPerKg
            var alignment = WeeklyDietReport.Alignment.uncertain
            var uncertainty: WeeklyDietReport.Uncertainty? = .insufficientWeight
            if let fit, let lo, let hi, hi - lo >= 21, fit.dayCount >= 6 {
                if start + 6 - hi > 7 { uncertainty = .staleWeight }
                else if evidencePairs.count != hi - lo || expected == nil { uncertainty = .missingCalories }
                else if evidence.contains(where: { $0.source == .unknown }) { uncertainty = .unknownBurnSource }
                else if evidence.contains(where: { $0.source == .calibrated }) { uncertainty = .calibratedBurn }
                else if evidence.contains(where: { $0.rough }) { uncertainty = .roughEstimates }
                else if fit.weeklyMarginKg > 0 && fit.weeklyMarginKg >= max(abs(expected!), abs(fit.slopeKgPerWeek)) {
                    uncertainty = .scatter
                } else {
                    uncertainty = nil
                    alignment = abs(fit.slopeKgPerWeek - expected!) <= max(fit.weeklyMarginKg, 0.000001) ? .consistent : .mismatch
                }
            }
            return WeeklyDietReport(startDay: start,
                intakeKcal: intake.isEmpty ? nil : intake.reduce(0, +),
                expenditureKcal: burn.isEmpty ? nil : burn.reduce(0, +),
                intakeDays: intake.count, expenditureDays: burn.count, pairedDays: paired.count,
                pairedBalanceKcal: paired.isEmpty ? nil : paired.reduce(0) { $0 + $1.intake! - $1.expenditure! },
                roughDays: week.filter { $0.intake != nil && $0.rough }.count,
                formulaDays: week.filter { $0.expenditure != nil && $0.source == .formula }.count,
                calibratedDays: week.filter { $0.expenditure != nil && $0.source == .calibrated }.count,
                meanWeightKg: weights.isEmpty ? nil : weights.reduce(0, +) / Double(weights.count),
                weighInDays: weights.count, fit: fit, evidenceStart: lo, evidenceEnd: hi,
                evidencePairedDays: evidencePairs.count, expectedKgPerWeek: expected, alignment: alignment, uncertainty: uncertainty)
        }
    }
}
