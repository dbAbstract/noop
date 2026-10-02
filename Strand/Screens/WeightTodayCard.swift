import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Today's weigh-in card
//
// A prompt when today has no weigh-in, a figure when it does, and a tap through to the full screen either
// way. It exists because weigh-ins were previously only reachable from the bottom of the food log, which is
// both the wrong place and an easy one to never find.
//
// WHAT IT SAYS WHEN THERE IS NO DATA is the load-bearing part. `AdaptiveExpenditureEngine` gates on
// weigh-in days exactly as hard as on intake days, so a user who logs food diligently and steps on the
// scale twice a week never gets a verdict — and nothing on the old surface told them that. A card that only
// appeared once there was something to show would have been useless for the one person who needed it.
struct WeightTodayCard: View {
    @EnvironmentObject var repo: Repository

    @AppStorage(FoodLogStore.enabledKey) private var foodEnabled = false
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent

    @State private var todayKg: Double?
    @State private var trend: WeightTrendFit?
    @State private var weighInDays = 0
    @State private var reloadTick = 0

    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    var body: some View {
        Group {
            // Rides the food-logging switch rather than a toggle of its own: a weigh-in with no food log is
            // a number with nothing to compare it against, and the engine needs both halves anyway.
            if foodEnabled {
                NavigationLink(value: TabRoute.weight) {
                    card
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: "\(repo.foodSeq)-\(reloadTick)") { await reload() }
    }

    private var card: some View {
        NoopCard(padding: 14, tint: todayKg == nil ? StrandPalette.chargeColor : StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: 10) {
                    Image(systemName: "scalemass")
                        .foregroundStyle(todayKg == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Weight")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }

                if let kg = todayKg {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.1f", locale: AppLanguage.activeLocale, kg))
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("kg today")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let fit = trend, fit.isDistinguishableFromZero {
                        // The RATE, not the raw change — a day-to-day difference is mostly water, and only
                        // the fitted line through several readings means anything.
                        Text("\(String(format: "%+.2f", locale: AppLanguage.activeLocale, fit.slopeKgPerWeek)) kg/week")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if trend != nil {
                        // Said plainly rather than showing a rate that cannot be told from zero, which is
                        // how someone concludes a diet is working or failing from noise.
                        Text("Not enough weigh-ins yet to call a direction.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Not logged today")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Names the CONSEQUENCE, because "log your weight" on its own is a chore and this is
                    // the half of the calibration people skip without knowing it costs them a verdict.
                    Text(weighInDays >= AdaptiveExpenditureEngine.minWeightReadings
                         ? String(localized: "Tap to add this morning's — the trend needs them regularly, not just often.")
                         : String(localized: "Tap to add it. NOOP needs \(AdaptiveExpenditureEngine.minWeightReadings) weigh-ins before it can work out your real expenditure — you have \(weighInDays)."))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(cardOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(todayKg == nil
                            ? String(localized: "Weight not logged today. Tap to log.")
                            : String(localized: "Weight today \(String(format: "%.1f", todayKg ?? 0)) kilograms. Tap for detail."))
    }

    private func reload() async {
        guard foodEnabled else { return }
        let rows = await repo.weightHistory(days: 90)
        todayKg = rows.first(where: { $0.day == Repository.localDayKey(Date()) })?.kg
        weighInDays = rows.count
        let readings = rows.compactMap { row -> WeightReading? in
            guard let idx = Repository.dayIndex(row.day) else { return nil }
            return WeightReading(dayIndex: idx, kg: row.kg)
        }
        trend = WeightTrend.fit(readings)
    }
}
