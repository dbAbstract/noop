import SwiftUI

// MARK: - Native Liquid Glass search field
//
// Shared search chrome for every in-app filter/search bar. iOS 26 uses the platform
// `glassEffect` capsule; macOS and older iOS keep a solid elevated pill (not a
// hand-rolled blur stack). Liquid Glass is intentionally iOS-only — macOS stays on
// the standard surface. Clear control, magnifying-glass glyph, and accessibility
// wiring stay identical across call sites.

/// Full-width rounded search field with native Liquid Glass on iOS 26+.
public struct NoopLiquidGlassSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let accessibilityPrompt: String
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    public init(text: Binding<String>,
                prompt: String,
                accessibilityLabel: String? = nil,
                isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.prompt = prompt
        self.accessibilityPrompt = accessibilityLabel ?? prompt
        self.externalFocus = isFocused
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(focusBinding)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .nativeLiquidGlassSearchChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrompt))
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }
}

public extension View {
    /// Capsule Liquid Glass search chrome. iOS 26 uses interactive `glassEffect`; macOS and older
    /// iOS use the shared elevated pill surface. Glass APIs stay behind `#if os(iOS)` so macOS
    /// (deployment 13) never type-checks or applies Liquid Glass.
    @ViewBuilder
    func nativeLiquidGlassSearchChrome() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.noopStandardSearchChrome()
        }
        #else
        self.noopStandardSearchChrome()
        #endif
    }

    /// Circular / capsule interactive Liquid Glass button chrome (Home header, live-workout controls,
    /// workout-selection close/chips). iOS 26 only; every other platform keeps the caller's
    /// `fallback` (standard material / press style) unchanged.
    @ViewBuilder
    func nativeLiquidGlassButtonChrome<Fallback: View>(
        controlSize: ControlSize = .small,
        capsule: Bool = false,
        @ViewBuilder fallback: () -> Fallback
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(capsule ? .capsule : .circle)
                .controlSize(controlSize)
        } else {
            fallback()
        }
        #else
        fallback()
        #endif
    }

    /// Liquid Glass finish for an in-content TOP BAR — a header the page scrolls underneath.
    ///
    /// Distinct from the search and button helpers in what it shapes: a bar spans the full width and is
    /// pinned to the top safe area, so it takes a `.rect` container with no corner radius at the top and
    /// a soft one below, and it must NOT be `.interactive()` — that modifier adds the press-response
    /// animation a control wants, and a bar is not pressable.
    ///
    /// The pre-26 fallback is a material rather than nothing: the whole point is that content passing
    /// beneath stays legible, and on a build without glass an unfilled bar would let text collide with
    /// text. `.ultraThinMaterial` is the closest honest approximation — it blurs what is behind without
    /// claiming to refract it.
    @ViewBuilder
    func nativeLiquidGlassBarChrome() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadii: .init(bottomLeading: 20,
                                                                    bottomTrailing: 20)))
        } else {
            self.noopBarMaterialChrome()
        }
        #else
        self.noopBarMaterialChrome()
        #endif
    }

    /// Blurred-material top bar, for builds without Liquid Glass.
    @ViewBuilder
    func noopBarMaterialChrome() -> some View {
        self
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial,
                        in: UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 20,
                                                                      bottomTrailing: 20)))
    }

    /// Interactive circular `glassEffect` finish layer (e.g. Home profile photo over glass).
    /// No-op outside iOS 26 so macOS never imports the glass path.
    @ViewBuilder
    func nativeLiquidGlassCircleFinish() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    private func noopStandardSearchChrome() -> some View {
        self.background(
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: false)
        )
    }
}
