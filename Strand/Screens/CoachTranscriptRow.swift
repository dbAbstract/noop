import SwiftUI
import MarkdownUI
import StrandDesign
import StrandAnalytics

// FORK-LOCAL. One transcript turn as a view, shared by both Coach transcripts: the SwiftUI `LazyVStack` (macOS,
// and iOS with the UIKit transcript turned off) and the UIKit collection view (`CoachTranscriptCollection`), which
// hosts this in its cells. Moved out of `CoachView` unchanged so the two paths cannot draw a turn differently.

/// Skip parsing unchanged replies when streaming or repository updates redraw the transcript.
struct CoachMarkdown: View, Equatable {
    let text: String
    let messageId: UUID

    var body: some View {
        Markdown(CoachMarkdownCache.shared.content(for: text, messageId: messageId))
            .markdownTheme(.strand)
    }

    static func == (lhs: CoachMarkdown, rhs: CoachMarkdown) -> Bool {
        lhs.text == rhs.text && lhs.messageId == rhs.messageId
    }
}

/// The assistant bubble while its reply streams in. Observes only `StreamingReply`, so the Coach screen is not
/// re-evaluated for every chunk; drawn exactly like a finished assistant bubble (same Markdown theme, inset
/// and width), and replaced by the finished one when the reply lands. No context menu until then.
struct StreamingBubble: View {
    @ObservedObject var reply: StreamingReply

    var body: some View {
        let text = reply.text
        let visible = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = reply.messageId, !visible.isEmpty, visible != "Today's brief" {
            HStack {
                CoachMarkdown(text: text, messageId: id)
                    .equatable()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NoopMetrics.chatTextInset)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach is replying: \(text)")
        }
    }
}

/// "Coach is thinking…", below the newest turn while a reply is on its way.
struct CoachTypingIndicator: View {
    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Text("Coach is thinking…")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
        }
        .padding(.horizontal, NoopMetrics.chatTextInset)
        .padding(.vertical, NoopMetrics.space2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coach is thinking")
    }
}

/// One turn: its time divider when it follows a real gap, the bubble, then whatever it proposed.
struct CoachTranscriptRow: View {
    /// Everything the row draws from, as values. A cell is reconfigured exactly when this changes.
    struct Model: Equatable {
        let message: ChatMessage
        let previousSentAt: Int?
        /// This turn is the reply arriving now and has no final text yet: draw the stream instead.
        let streaming: Bool
        let sending: Bool

        init(message: ChatMessage, previousSentAt: Int?, streamingId: UUID?, sending: Bool) {
            self.message = message
            self.previousSentAt = previousSentAt
            self.streaming = message.id == streamingId && CoachTranscriptRow.isEmptyPlaceholder(message)
            self.sending = sending
        }

        /// The rows for a transcript, each knowing the turn before it (for its time divider).
        static func rows(_ messages: [ChatMessage], streamingId: UUID?, sending: Bool) -> [Model] {
            messages.indices.map { i in
                Model(message: messages[i], previousSentAt: i > 0 ? messages[i - 1].sentAt : nil,
                      streamingId: streamingId, sending: sending)
            }
        }
    }

    let model: Model
    let streaming: StreamingReply
    let onRetry: (UUID) -> Void
    let onSaveAdvice: (String) -> Void

    var body: some View {
        let message = model.message
        VStack(alignment: .leading, spacing: 8) {
            // A coach conversation runs the length of a day, so two adjacent
            // bubbles can be six hours apart with nothing on screen to say so.
            // The threshold lives in `ChatTimeSeparator`, tested, because "is
            // this a pause or a break" is the entire design of the feature.
            if ChatTimeSeparator.needsSeparator(previousSentAt: model.previousSentAt, sentAt: message.sentAt) {
                timeSeparator(message.sentAt)
            }
            // An assistant turn with no text yet is the STREAMING PLACEHOLDER —
            // `send` appends it so deltas have somewhere to land. Drawn, it is an
            // empty bubble sitting above "Coach is thinking…", which is two things
            // on screen for one state. The typing indicator IS its visual.
            //
            // Also catches a reply that is nothing but an action block mid-stream:
            // `displayText` hides the JSON, so the bubble would be empty for real.
            if model.streaming {
                // The reply arriving now: its own view observes the stream, so a
                // chunk redraws this bubble and nothing else on the screen.
                StreamingBubble(reply: streaming)
            } else if !Self.isEmptyPlaceholder(message) {
                bubble(message)
            }
            // The proposal card rides UNDER its own turn rather than inside the
            // bubble: it is not prose, it is not selectable, and it must not be
            // swept up by the bubble's Copy/Share context menu.
            // Two or more foods in one turn are one meal: a single card with one
            // Log tap (items can still be dropped). Everything else — and a lone
            // food — keeps its own card.
            let meal = message.proposals.filter(MealProposalCard.groups)
            if meal.count >= 2 {
                MealProposalCard(proposals: meal, messageId: message.id)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            ForEach(message.proposals.filter { meal.count < 2 || !MealProposalCard.groups($0) }) { proposal in
                FoodProposalCard(proposal: proposal, messageId: message.id)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            if let proposal = message.dietProposal {
                CoachDietProposalCard(proposal: proposal, messageId: message.id)
            }
            if let failure = message.failure {
                retryRow(message: message, reason: failure)
            }
        }
    }

    /// An assistant turn with nothing to show yet.
    ///
    /// Only ever true for the ASSISTANT: a user bubble with empty text cannot happen (`send` rejects a
    /// blank question), and treating one as a placeholder would silently hide a real turn.
    static func isEmptyPlaceholder(_ message: ChatMessage) -> Bool {
        message.role == .assistant
            && (message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || message.text == "Today's brief\n\n")
    }

    /// Local days since 1970, matching the app's day-key convention.
    static func localEpochDay(_ date: Date) -> Int {
        let start = Calendar.current.startOfDay(for: date)
        return Int((start.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// A failed turn carries its own reason and its own retry.
    ///
    /// Attached to the MESSAGE rather than shown as a banner, because a banner says "something failed" and
    /// this says "this one did, press here". The alternative the user was left with was copying their own
    /// text out and pasting it back — which they did five times, each one re-sending a longer history.
    @ViewBuilder
    private func retryRow(message: ChatMessage, reason: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                Text(reason)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onRetry(message.id)
                } label: {
                    Label("Send again", systemImage: "arrow.clockwise")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(model.sending)
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // LLM replies arrive as Markdown (bold, lists, headings, tables), rendered with the
            // chat-bubble-sized Strand theme. User bubbles stay verbatim `Text` so typed `*`/`#` never
            // turn into surprise formatting.
            //
            // NO SURFACE BEHIND THE REPLY. The assistant's text is the bulk of this screen and it used to
            // sit on a frosted card, which cost it horizontal room, boxed long answers into a column
            // inside a column, and spent the app's strongest visual signal on the one thing that is
            // always present. Flat on the page, it reads as prose.
            //
            // Authorship survives the change because the USER's bubble keeps its fill: one side tinted
            // and the other bare is all the distinction a two-party transcript needs, and it is the
            // arrangement every chat app converges on.
            //
            // The LOG / NEW FOOD proposal cards keep their surface, and that contrast now MEANS
            // something — a card is where there is a decision to make, rather than decoration prose
            // happened to be wearing too.
            //
            // K8: context menu (long-press / right-click) with Copy, Share, and Save actions.
            HStack {
                CoachMarkdown(text: message.text, messageId: message.id)
                    .equatable()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // Padding with NO background, which looks like a no-op and is not. The context menu
                    // draws its long-press highlight around this view's bounds, and with the bounds flush
                    // to the glyphs the rounded highlight clipped the corner characters. The card used to
                    // supply this inset; removing the card removed it too.
                    .padding(.horizontal, NoopMetrics.chatTextInset)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 620, alignment: .leading)
                    // K8: Copy / Share / Save context menu on assistant replies.
                    .contextMenu {
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            #else
                            UIPasteboard.general.string = message.text
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: message.text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            onSaveAdvice(message.text)
                        } label: {
                            Label("Save to Journal", systemImage: "square.and.pencil")
                        }
                    }
                // Narrower than the user side's 48: with no fill there is no shape to break up, so the
                // text may use nearly the full column, which is the point of removing the card.
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said: \(message.text)")
        }
    }

    /// A centred date/time divider between turns separated by a real gap.
    ///
    /// Spells the day out only when it is not today: "10:54" alone is unambiguous within a day and the
    /// word "Today" in front of every divider in a one-day conversation is noise. Yesterday is named;
    /// anything older carries its date, because by the third day back a weekday name is no easier to
    /// place than the date itself.
    private func timeSeparator(_ sentAt: Int) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(sentAt))
        let bucket = ChatTimeSeparator.dayBucket(
            messageEpochDay: Self.localEpochDay(date),
            todayEpochDay: Self.localEpochDay(Date()))
        let time = date.formatted(date: .omitted, time: .shortened)
        let text: String
        switch bucket {
        case .today:     text = time
        case .yesterday: text = String(localized: "Yesterday") + " " + time
        case .earlier:   text = date.formatted(date: .abbreviated, time: .omitted) + " " + time
        }
        return HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(text)
    }
}
