import SwiftUI

/// Phase 14: magazine pull-quote treatment for the celebrity coach.
/// Replaces `SpeechBubble` in revisit (saved-meal) contexts.
///
/// Layout matches mockup-2-result.svg lines 95–101:
///   "                          ← 64pt M PLUS Black, brand @ 55%
///     E = mc²… and a slice of  ← italic body-emphasis ink
///     pizza ≈ 285 kcal.
///     Pace thyself.
///     ───                       ← 36pt rule, 1.5pt, ink
///     Albert Einstein           ← caption-strong inkMute
///
/// The opening glyph uses a typographic open-quote ("\u{201C}", curly
/// double quote) rather than a straight quote, since the typeface
/// renders curly forms idiomatically. The visual-only glyph carries
/// `accessibilityHidden(true)` so screen readers don't read it as
/// "double quotation mark".
///
/// Phase 14 typewriter restore: when `typewriter: true`, the body text
/// types out char-by-char (20 ms/char) on first appear after an optional
/// `startDelay`. The attribution rule + name fade in *after* the text
/// finishes typing — the quote feels like the coach is writing it live.
/// Used by `AnalysisResultView` for the post-analyze magic moment.
struct EditorialQuote: View {
    let text: String
    var attribution: String? = nil
    /// When true, `text` types out char-by-char. Defaults to false so
    /// revisit contexts (saved-meal expansions) render instantly.
    var typewriter: Bool = false
    /// Seconds to wait before starting the typewriter. Lets the parent
    /// stagger this quote against other typewriter elements.
    var startDelay: Double = 0

    @State private var displayed: String = ""
    @State private var attributionVisible: Bool = false
    @State private var didStart: Bool = false

    private var renderedText: String {
        typewriter ? displayed : text
    }

    private var showAttribution: Bool {
        guard let a = attribution, !a.isEmpty else { return false }
        return typewriter ? attributionVisible : true
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            // Open-quote glyph at hero scale, brand at 55% opacity.
            // We cap its frame so it doesn't dominate vertical layout.
            Text("\u{201C}")
                .font(.custom(AppFont.PS.mplusBlack, size: 64))
                .foregroundStyle(Color.brand.opacity(0.55))
                .frame(width: 32, height: 28, alignment: .topLeading)
                .offset(y: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(renderedText)
                    .appFont(.bodyEmphasis)
                    .italic()
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if showAttribution, let attribution {
                    HStack(spacing: AppSpacing.sm) {
                        Rectangle()
                            .fill(Color.ink)
                            .frame(width: 36, height: 1.5)
                        Text(attribution)
                            .appFont(.captionStrong)
                            .foregroundStyle(Color.inkMute)
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            attribution.map { "\(text). — \($0)" } ?? text
        )
        .onAppear { startIfNeeded() }
    }

    private func startIfNeeded() {
        guard typewriter, !didStart else { return }
        didStart = true
        Task { @MainActor in
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }
            let chars = Array(text)
            for c in chars {
                if Task.isCancelled { return }
                displayed.append(c)
                try? await Task.sleep(nanoseconds: UInt64(0.02 * 1_000_000_000))
            }
            withAnimation(.appEntrance) {
                attributionVisible = true
            }
        }
    }
}

#if DEBUG
#Preview("EditorialQuote — variations") {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
        EditorialQuote(
            text: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself.",
            attribution: "Albert Einstein"
        )
        EditorialQuote(
            text: "Hark! This dish containeth more sugar than the Globe Theatre's punch bowl on a Saturday eve.",
            attribution: "William Shakespeare"
        )
        EditorialQuote(
            text: "Anonymous wisdom — the best meal is the one you remember tomorrow."
        )
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}

#Preview("EditorialQuote — typewriter") {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
        EditorialQuote(
            text: "E = mc²… and a slice of pizza ≈ 285 kcal. Pace thyself.",
            attribution: "Albert Einstein",
            typewriter: true,
            startDelay: 0.4
        )
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}
#endif
