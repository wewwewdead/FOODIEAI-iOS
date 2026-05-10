import SwiftUI

/// Phase 14: 32pt-tall floating pill that sits over the photo on Result.
/// Matches mockup-2-result.svg lines 52–58.
///
/// Layout:
///   ⨀ AE  Albert Einstein
///
/// 20pt avatar circle (single uppercase initial in `bgCanvas` over `ink`)
/// + name text in `caption-strong` `ink`. White surface with
/// `shadow-floating`. Sits in the parent's coordinate space — typically
/// padded into the bottom-leading corner of the photo card via `.overlay`
/// or `.bottomLeading` ZStack alignment.
struct CoachBadge: View {
    let name: String

    private var initials: String {
        name.split(separator: " ")
            .compactMap { $0.first.map(Character.init) }
            .prefix(2)
            .map(String.init)
            .joined()
            .uppercased()
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.ink)
                    .frame(width: 20, height: 20)
                Text(initials.isEmpty ? "?" : initials)
                    .appFont(.caption)
                    .foregroundStyle(Color.bgCanvas)
            }
            Text(name)
                .appFont(.captionStrong)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(
            Capsule().fill(Color.bgSurface)
        )
        .appShadow(.shadowFloating)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach \(name)")
    }
}

#if DEBUG
#Preview("CoachBadge — over a photo") {
    ZStack(alignment: .bottomLeading) {
        // Stand-in for the photo card.
        RoundedRectangle(cornerRadius: AppRadius.xl)
            .fill(LinearGradient(
                colors: [
                    Color(red: 232/255, green: 184/255, blue: 92/255),
                    Color(red: 154/255, green:  74/255, blue: 31/255)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 354, height: 265)

        CoachBadge(name: "Albert Einstein")
            .padding(20)
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.bgCanvas)
}
#endif
