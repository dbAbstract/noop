import SwiftUI
import StrandDesign
import StrandAnalytics

/// Small local reminder. Queries run when evidence or the civil day changes, never per streamed token.
struct CoachWeeklyReviewBanner: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FoodLogStore.enabledKey) private var foodEnabled = false
    @AppStorage(CoachDietReviewHistory.dateKey) private var reviewedAt = 0.0
    @State private var reviewDay = Repository.localDayKey(Date())
    @State private var reports: [WeeklyDietReport] = []
    @State private var showReports = false

    private var isReady: Bool {
        _ = reviewedAt
        return reports.first.map { !CoachDietReviewHistory.hasReviewed(week: $0.startKey) } ?? false
    }

    var body: some View {
        Group {
            if foodEnabled && isReady {
                Button("Last week’s diet review is ready") { showReports = true }
                    .buttonStyle(NoopButtonStyle(.secondary))
            }
        }
        .sheet(isPresented: $showReports) {
            WeeklyDietReviewView(reports: reports, onDiscuss: { week in
                showReports = false
                coach.pendingPrompt = CoachDietReviewHistory.weeklyPrompt(startKey: week.startKey)
            }, canDiscuss: coach.isConfigured && coach.dataConsent && !coach.sending)
        }
        .task(id: "\(foodEnabled)-\(repo.foodSeq)-\(reviewDay)") {
            guard foodEnabled else { reports = []; return }
            do {
                let loaded = try await repo.weeklyDietReports()
                guard !Task.isCancelled else { return }
                reports = loaded
            } catch {
                if !Task.isCancelled { reports = [] }
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active { reviewDay = Repository.localDayKey(Date()) }
        }
    }
}
