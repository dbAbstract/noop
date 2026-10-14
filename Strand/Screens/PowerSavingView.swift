import SwiftUI
import StrandDesign

/// Exclusive sync schedules project the existing preferences without changing BLE policy.
struct PowerSavingView: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    @State private var exporting = false
    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey) private var powerSavingPct = 20
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey) private var pauseHrvDisabled = false
    @AppStorage(PuffinExperiment.lowRefreshKey) private var lowRefreshEnabled = false
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrv = false

    private enum Schedule: Hashable { case standard, adaptive, hourly }
    private var schedule: Schedule {
        !powerSavingEnabled ? .standard : lowRefreshEnabled ? .hourly : .adaptive
    }
    private var scheduleBinding: Binding<Schedule> {
        Binding(get: { schedule }, set: { value in
            lowRefreshEnabled = value == .hourly
            powerSavingEnabled = value != .standard
            model.applyPowerSaving()
        })
    }
    private var thresholdBinding: Binding<Double> {
        Binding(get: { Double(max(10, min(35, powerSavingPct == 0 ? 20 : powerSavingPct))) },
                set: { powerSavingPct = Int($0) })
    }

    var body: some View {
        ScreenScaffold(title: "Power saving", subtitle: "Choose how often NOOP syncs and when background HRV pauses.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Background sync").font(StrandFont.headline)
                        Picker("Sync schedule", selection: scheduleBinding) {
                            Text("Standard — every 15 minutes").tag(Schedule.standard)
                            Text("Adaptive — 15 or 45 minutes").tag(Schedule.adaptive)
                            Text("Hourly — every 60 minutes").tag(Schedule.hourly)
                        }.pickerStyle(.menu)
                        Text(scheduleExplanation).font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text("These choices change periodic history transfers, not sensor sampling. Pull to sync, reconnects and strap events may sync sooner; empty-history backoff may delay them.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Continuous HRV capture").font(StrandFont.headline)
                        Text("Hourly sync does not turn off continuous HRV. The live stream and history transfers are separate battery costs.")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        if !continuousHrv {
                            Text("Continuous HRV capture is off. These pause controls do not enable it.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        if schedule != .standard {
                            Toggle("Pause background HRV at low battery", isOn: Binding(
                                get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 }))
                                .tint(StrandPalette.accent)
                                .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
                            Text("Pausing can leave gaps in HRV data. Live screens can still request heart rate. Background capture resumes above the threshold or while charging.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        } else {
                            Text("Standard sync leaves continuous HRV unchanged. Choose Adaptive or Hourly to add a low-battery pause.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                if schedule == .adaptive || (schedule == .hourly && !pauseHrvDisabled) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            HStack {
                                Text("Low strap battery threshold").font(StrandFont.headline)
                                Spacer()
                                Text(verbatim: "\(Int(thresholdBinding.wrappedValue))%")
                                    .font(StrandFont.headline).foregroundStyle(StrandPalette.accent)
                            }
                            Slider(value: thresholdBinding, in: 10...35, step: 5,
                                   onEditingChanged: { editing in if !editing { model.applyPowerSaving() } })
                                .tint(StrandPalette.accent)
                                .accessibilityLabel("Low strap battery threshold")
                            Text(schedule == .hourly
                                 ? "With Hourly selected, this threshold only controls the optional HRV pause. Sync remains hourly at every battery level."
                                 : "Adaptive sync uses 45 minutes at or below this threshold while discharging, and 15 minutes otherwise. The optional HRV pause uses the same threshold.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Battery diagnostics").font(StrandFont.headline)
                        if let rate = live.batteryPointsPerDay {
                            LabeledContent("Battery loss", value: String(localized: "\(rate.formatted(.number.precision(.fractionLength(1)))) pts/day"))
                                .font(StrandFont.body)
                            Text("Measured from recent battery readings. Percentage points per day, not percent of remaining charge.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        } else {
                            Text("Battery loss will appear after enough discharge readings are available. Hidden while charging.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text("Battery readings, connection time, traffic and sync activity are kept locally for up to 14 days and included in the strap-log export. Export from More → Test Centre → Report after a day of normal use.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        Button("Export battery diagnostics") {
                            exporting = true
                            Task {
                                defer { exporting = false }
                                let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
                                FileExport.exportText(model.live.exportableLogText(extraHeaderLines: extra),
                                    suggestedName: FileExport.timestampedName("noop-battery-log", ext: "txt"))
                            }
                        }.buttonStyle(NoopButtonStyle(.secondary)).disabled(exporting)
                    }
                }
            }
        }
        .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
        .onChangeCompat(of: lowRefreshEnabled) { _ in model.applyPowerSaving() }
    }

    private var scheduleExplanation: String {
        switch schedule {
        case .standard: return String(localized: "Periodic sync every 15 minutes at any battery level. Low-battery protection is off.")
        case .adaptive: return String(localized: "Periodic sync every 15 minutes normally, or every 45 minutes when the strap is low and not charging.")
        case .hourly: return String(localized: "Periodic sync every hour at any battery level. Adaptive sync timing is replaced by this schedule.")
        }
    }
}
