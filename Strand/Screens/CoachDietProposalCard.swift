import SwiftUI
import StrandDesign
import StrandAnalytics

/// Review first, then save through the existing validated goal editor.
struct CoachDietProposalCard: View {
    let proposal: CoachDietProposal
    let messageId: UUID
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var showEditor = false
    @State private var stale = false
    @State private var checking = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Coach proposal").font(StrandFont.headline)
                if let plan = proposal.appliedPlan {
                    HStack {
                        Text("Goal weight").font(StrandFont.body)
                        Spacer()
                        HStack(spacing: NoopMetrics.space1) {
                            Text(plan.targetWeightKg.formatted())
                            Text("kg")
                        }.font(StrandFont.body)
                    }
                    HStack {
                        Text("Timeline").font(StrandFont.body)
                        Spacer()
                        Text("\(plan.months)").font(StrandFont.body)
                        Text("months").font(StrandFont.body)
                    }
                } else {
                    Text("Proposed goal weight: \(proposal.request.targetWeightKg.formatted()) kg")
                        .font(StrandFont.body)
                    Text("Proposed timeline: \(proposal.request.months) months").font(StrandFont.body)
                    Text(proposal.request.reason).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if proposal.state == .pending {
                    Button("Review and edit goal") {
                        guard !checking else { return }
                        checking = true
                        Task {
                            guard await repo.currentDietGoal() == proposal.previousGoal else {
                                checking = false
                                stale = true
                                coach.updateDietProposal(messageId: messageId, state: .dismissed)
                                return
                            }
                            checking = false
                            showEditor = true
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.primary))
                    .disabled(checking)
                    Button("Dismiss") { coach.updateDietProposal(messageId: messageId, state: .dismissed) }
                        .buttonStyle(NoopButtonStyle(.secondary))
                } else {
                    Text(proposal.state == .applied ? "Goal saved" : "Dismissed")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            DietGoalSheet(existing: proposal.previousGoal, suggestion: proposal.request,
                          onPlanSaved: { plan, protein in
                coach.updateDietProposal(messageId: messageId, state: .applied,
                                         appliedPlan: plan, proteinGPerKg: protein)
            }) { }
            .environmentObject(repo)
            .environmentObject(profile)
        }
        .alert("Your goal has changed", isPresented: $stale) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This proposal refers to an older plan. Ask Coach to review your current goal instead.")
        }
    }
}
