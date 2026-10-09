import SwiftUI
import StrandDesign

/// Typing and speech updates invalidate this view, leaving the transcript and header untouched.
struct CoachComposer: View {
    let sending: Bool
    @Binding var focused: Bool
    let reset: Int
    let onSend: (String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = UserDefaults.standard.string(forKey: "coach.composerDraft") ?? ""
    @FocusState private var composerFocused: Bool
    private static let draftKey = "coach.composerDraft"
    private static let composerRadius: CGFloat = 20
    #if os(iOS)
    @StateObject private var voiceInput = CoachVoiceInput()
    #endif

    var body: some View {
        composer
            .task(id: draft) {
                // Coalesce draft saves while typing; leaving the screen or sending flushes immediately.
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                saveDraft()
            }
            .onDisappear {
                saveDraft()
                #if os(iOS)
                if voiceInput.isRecording { voiceInput.stopTranscribing { _ in } }
                #endif
            }
            .onChangeCompat(of: scenePhase) { phase in
                if phase != .active { saveDraft() }
            }
            .onChangeCompat(of: composerFocused) { value in
                if focused != value { focused = value }
            }
            .onChangeCompat(of: focused) { value in
                if composerFocused != value { composerFocused = value }
            }
            .onChangeCompat(of: reset) { _ in
                draft = ""
                saveDraft()
                composerFocused = false
            }
    }

    private func saveDraft() {
        UserDefaults.standard.set(draft, forKey: Self.draftKey)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        draft = ""
        saveDraft()
        composerFocused = false
        onSend(trimmed)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            // K4: on-device voice input (iOS only). macOS compiles this section out entirely.
            #if os(iOS)
            micButton
            #endif

            // Docked icon-only send affordance: a crisp accent-filled square sized to the
            // composer row (not the full 48pt control height), so it routes through the same
            // token fill/label colours as the button system without overpowering the field.
            Button {
                send(draft)
            } label: {
                Group {
                    if sending {
                        ProgressView().controlSize(.small).tint(StrandPalette.goldDeepText)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                // A CIRCLE, not a rounded square. Inside a capsule the square's corners fought the pill's
                // curve and the send read as a separate control that had been parked there.
                .frame(width: 38, height: 38)
                .foregroundStyle(StrandPalette.goldDeepText)
                .background(StrandPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(6)
        // A ROUNDED RECTANGLE, not a capsule. A capsule's corner radius is half its height, so a composer
        // that grows to four lines becomes a stadium with the text marooned in the middle of two huge
        // arcs. A fixed radius keeps the same shape at every height.
        //
        // And an OPAQUE FILL rather than glass. Glass takes its tone from what is behind it, which on a
        // flat dark page is barely a surface at all — the composer read as text floating on the page.
        // `surfaceRaised` is the token for "a layer above the page", which is what this is.
        .background(StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Self.composerRadius, style: .continuous))
        // The ring says which surface is taking the typing; unfocused it draws a hairline so the
        // composer keeps a defined edge.
        .overlay(RoundedRectangle(cornerRadius: Self.composerRadius, style: .continuous)
            .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline,
                          lineWidth: 1))
    }

    // MARK: - K4: Voice input (iOS only)

    #if os(iOS)
    /// Mic button: starts/stops on-device speech recognition. Disabled when the locale lacks
    /// on-device support or permission is denied; tapping when permission is not yet determined
    /// triggers the system prompt.
    private var micButton: some View {
        Button {
            toggleVoice()
        } label: {
            Group {
                if voiceInput.isRecording {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(StrandPalette.statusCritical)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canUseVoice ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                }
            }
            .frame(width: 36, height: 38)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!micButtonEnabled)
        .help(voiceInput.statusMessage ?? "Ask out loud")
        .accessibilityLabel(voiceInput.isRecording ? "Stop voice input" : "Voice input")
        .accessibilityHint(voiceInput.statusMessage ?? "Transcribes your question on-device")
        .task {
            // Pre-check on appear so the button reflects the right state without a tap.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { _ in }
            }
        }
    }

    /// Whether the mic button is tappable: not while sending, and only if voice is either
    /// already usable or permission hasn't been asked yet (first tap triggers the prompt).
    private var canUseVoice: Bool { voiceInput.canUseVoice }
    private var micButtonEnabled: Bool {
        !sending && (canUseVoice || voiceInput.authorization == .notDetermined)
    }

    private func toggleVoice() {
        if voiceInput.isRecording {
            voiceInput.stopTranscribing { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Append to the draft (not replace) so a user can speak into existing text.
                    draft = draft.isEmpty ? trimmed : "\(draft) \(trimmed)"
                }
            }
        } else {
            // First tap with undetermined permission triggers the system prompt; if granted,
            // start transcribing immediately on the next tap. If already authorized, start now.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { state in
                    if state == .authorized {
                        voiceInput.startTranscribing { partial in
                            draft = partial
                        }
                    }
                }
            } else {
                voiceInput.startTranscribing { partial in
                    draft = partial
                }
            }
        }
    }
    #endif

}
