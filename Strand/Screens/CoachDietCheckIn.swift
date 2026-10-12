import SwiftUI
import StrandDesign
import StrandAnalytics

/// Local weekly check-in. A tap hands the review to Coach's existing consent and provider boundary.
struct CoachDietCheckIn: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("noop.coachEnabled") private var coachEnabled = true
    @AppStorage(FoodLogStore.enabledKey) private var foodEnabled = false
    @AppStorage(CoachDietReviewHistory.dateKey) private var reviewedAt = 0.0
    @State private var snapshot: CoachDietSnapshot?
    @State private var reports: [WeeklyDietReport] = []
    @State private var showReports = false
    @State private var reportsFailed = false
    @State private var reviewDay = Repository.localDayKey(Date())

    var body: some View {
        Group {
            if foodEnabled, let snapshot {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Diet check-in").font(StrandFont.headline)
                        if let latest = reports.first {
                            Text(latestTitle(latest))
                                .font(StrandFont.body)
                            Text(verbatim: "\(latest.startKey) – \(latest.endKey)")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Button("Weekly reports and history") { showReports = true }
                            .buttonStyle(NoopButtonStyle(.secondary))
                        if reportsFailed {
                            Text("Weekly reports could not be loaded. Try opening Diet again.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        if coachEnabled {
                            if reports.isEmpty {
                                Text(summary(snapshot)).font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Text("Coach can review your plan and logging habits with you. Changes are yours to review and save.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            Button {
                                // The configured Coach sends only after the user requests this review.
                                // An unconfigured provider opens setup, with no pending automatic send.
                                if coach.isConfigured && coach.dataConsent {
                                    coach.pendingPrompt = reports.first.map { CoachDietReviewHistory.weeklyPrompt(startKey: $0.startKey) } ?? CoachDietReviewHistory.prompt
                                }
                                dismiss()
                                router.openCoach()
                            } label: {
                                Text(coach.isConfigured && coach.dataConsent ? "Review diet progress" : "Set up Coach")
                            }
                            .buttonStyle(NoopButtonStyle(.primary))
                            .disabled(coach.sending)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showReports) {
            WeeklyDietReviewView(reports: reports, onDiscuss: { week in
                coach.pendingPrompt = CoachDietReviewHistory.weeklyPrompt(startKey: week.startKey)
                showReports = false
                dismiss()
                router.openCoach()
            }, canDiscuss: coachEnabled && coach.isConfigured && coach.dataConsent && !coach.sending)
        }
        .task(id: "\(repo.foodSeq)-\(foodEnabled)-\(coachEnabled)-\(reviewDay)") {
            guard foodEnabled else { snapshot = nil; return }
            let loadedSnapshot = await repo.coachDietSnapshot()
            do {
                let loadedReports = try await repo.weeklyDietReports()
                guard !Task.isCancelled else { return }
                snapshot = loadedSnapshot
                reports = loadedReports
                reportsFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                snapshot = loadedSnapshot
                reports = []
                reportsFailed = true
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active { reviewDay = Repository.localDayKey(Date()) }
        }
    }

    private func latestTitle(_ latest: WeeklyDietReport) -> String {
        // Observe the existing successful-review timestamp so completion updates this card too.
        _ = reviewedAt
        return CoachDietReviewHistory.hasReviewed(week: latest.startKey)
            ? String(localized: "Last week’s review is available") : String(localized: "Last week’s diet review is ready")
    }

    private func summary(_ snapshot: CoachDietSnapshot) -> String {
        // Reading the persisted timestamp updates this card when a review finishes elsewhere.
        let due = reports.first.map { !CoachDietReviewHistory.hasReviewed(week: $0.startKey) }
            ?? (reviewedAt <= 0 || CoachDietReviewHistory.isDue(goalId: snapshot.goal?.id))
        if !due { return String(localized: "Your weekly check-in is in Coach. You can revisit it whenever you need.") }
        switch snapshot.signal {
        case .noGoal: return String(localized: "Set a goal and timeline together with Coach.")
        case .building: return String(localized: "Progress is still uncertain. Review what you have logged and what evidence is needed next.")
        case .staleWeight: return String(localized: "A recent weigh-in would help assess progress. Coach can help you plan your next check-in.")
        case .onTrack: return String(localized: "Your measured trend is consistent with the plan. Your weekly review is ready.")
        case .slower: return String(localized: "Your measured trend is slower than the plan predicts. Review logging consistency and the plan before adjusting it.")
        case .faster: return String(localized: "Your measured trend is faster than the plan predicts. Review whether the current plan still suits you.")
        case .goalReached: return String(localized: "Your weight trend has reached the goal. Discuss what you want to do next with Coach.")
        }
    }
}
