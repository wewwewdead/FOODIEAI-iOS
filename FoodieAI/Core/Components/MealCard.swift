import SwiftUI

/// Phase 14: photo-first meal row for the Tracker list.
///
/// 76pt tall; white surface; `radius-lg` (20pt). Layout matches
/// mockup-3-tracker.svg lines 83–94:
///   - 56×56 thumbnail on the left, `radius-md` (16pt) clip
///   - food name in `title-1` (20pt), then meta line
///     "12:30 PM · 285 cal" in caption `inkLight`,
///     then macros line "35g carbs · 4g sugar · 12g protein" in
///     `caption-strong` `inkMute`
///   - trailing chevron in `inkLight`
///
/// Replaces `MealRow` in the Today list. The Phase 10 `MealRow` keeps
/// its expanded-in-place behavior in DayDetailSheet for now; eventually
/// that surface will migrate too.
///
/// Tap delegates to `onTap` — the parent decides whether to expand
/// inline, present a sheet, or open a detail screen.
///
/// Image loading reuses the Phase 12 `FoodImageService.cachedSignedURL`
/// path with the same fallback chain (`imageThumbPath ?? imagePath`),
/// so pre-Phase-12 rows continue to render via the larger main object.
struct MealCard: View {
    let log: FoodLog
    let onTap: () -> Void
    /// When true, the food name may wrap to two lines and the row grows
    /// to fit. Used by `ExpandableMealCard` so a long name like "Korean
    /// meal with spicy pork stew" reads fully once the card is opened
    /// without changing collapsed-row layout elsewhere.
    var expandsName: Bool = false

    @State private var imageURL: URL?
    @State private var failed: Bool = false
    /// Drives the full-image-viewer fullScreenCover when the user taps
    /// the thumbnail. Restored from v1 MealRow — the redesigned card had
    /// collapsed everything into a single expansion-only tap surface.
    @State private var showFullImage: Bool = false

    private static let imageService = FoodImageService()

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            thumbnailButton

            Button {
                Haptics.tap()
                onTap()
            } label: {
                HStack(spacing: AppSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.foodName)
                            .appFont(.title2)
                            .foregroundStyle(Color.ink)
                            .lineLimit(expandsName ? nil : 1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: expandsName)
                        Text(metaLine)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkLight)
                            .lineLimit(1)
                        Text(macrosLine)
                            .appFont(.caption)
                            .foregroundStyle(Color.inkMute)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.inkLight)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(log.foodName), \(metaLine), \(macrosLine)"
            )
        }
        .padding(.horizontal, AppSpacing.sm + 2)
        .padding(.vertical, AppSpacing.sm + 2)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .appShadow(.shadowCard)
        .task { await loadThumbnail() }
        .fullScreenCover(isPresented: $showFullImage) {
            FullImageViewer(imagePath: log.imagePath ?? log.imageThumbPath ?? "")
        }
    }

    /// Thumbnail wrapped in a Button so a tap on the image opens the
    /// full-screen viewer. Disabled (just renders the thumbnail) if the
    /// row has no usable storage path — defensively, since saved meals
    /// always have one.
    @ViewBuilder
    private var thumbnailButton: some View {
        let canViewFull = !((log.imagePath ?? log.imageThumbPath)?.isEmpty ?? true)
        if canViewFull {
            Button {
                Haptics.tap()
                showFullImage = true
            } label: {
                thumbnailFrame
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full image")
        } else {
            thumbnailFrame
        }
    }

    private var thumbnailFrame: some View {
        thumbnail
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(Color.borderHairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure:          placeholder
                case .empty:            placeholder
                @unknown default:       placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.bgSurfaceSoft
            Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.inkLight)
        }
    }

    private var metaLine: String {
        let t = Self.timeFormatter.string(from: log.eatenAt)
        return "\(t) · \(format(log.calories)) cal"
    }

    /// Cached `DateFormatter` — see `MealRow.timeFormatter` for the same
    /// reasoning (ICU/calendar bootstrap is expensive, rendered per row).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()

    private var macrosLine: String {
        // Compact 3-macro line; protein/fat/fiber drop here so the row
        // stays scannable. The expanded MealRow still shows everything.
        var parts: [String] = []
        parts.append("\(format(log.carbsG))g carbs")
        parts.append("\(format(log.sugarG))g sugar")
        if let p = log.proteinG { parts.append("\(format(p))g protein") }
        return parts.joined(separator: " · ")
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "—" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }

    private func loadThumbnail() async {
        guard imageURL == nil, !failed else { return }
        let path: String? = log.imageThumbPath ?? log.imagePath
        guard let path, !path.isEmpty else { return }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: path)
            await MainActor.run { self.imageURL = url }
        } catch {
            #if DEBUG
            NSLog("[FoodImage] sign failed for %@: %@", path, "\(error)")
            #endif
            await MainActor.run { self.failed = true }
        }
    }
}

/// Subtle press state — scale 0.98 with `.appPress`. The card already
/// carries `shadowCard`, so a lift effect would feel heavy.
private struct MealCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.appPress, value: configuration.isPressed)
    }
}

#if DEBUG
#Preview("MealCard — two cards") {
    VStack(spacing: AppSpacing.md) {
        MealCard(log: .preview(name: "Margherita Pizza",
                                calories: 285, carbs: 35, sugar: 4,
                                protein: 12, time: "12:30 PM"),
                 onTap: {})
        MealCard(log: .preview(name: "Greek Salad",
                                calories: 962, carbs: 107, sugar: 24,
                                protein: 40, time: "7:15 AM"),
                 onTap: {})
    }
    .padding(AppSpacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.bgCanvas)
}

private extension FoodLog {
    static func preview(name: String,
                        calories: Double,
                        carbs: Double,
                        sugar: Double,
                        protein: Double,
                        time: String) -> FoodLog {
        // Build an `eatenAt` matching the displayed time so the preview
        // meta-line reads as designed without a fake formatter override.
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        let parsed = f.date(from: time) ?? Date()
        return FoodLog(
            id: UUID(),
            userId: UUID(),
            foodName: name,
            imagePath: nil,
            imageThumbPath: nil,
            calories: calories,
            carbsG: carbs,
            sugarG: sugar,
            proteinG: protein,
            fatG: nil,
            fiberG: nil,
            benefits: [],
            drawbacks: [],
            nutrients: [],
            coachName: nil,
            coachAdvice: nil,
            eatenAt: parsed,
            createdAt: Date(),
            origin: .analyzed,
            sourceLogId: nil,
            mood: nil
        )
    }
}
#endif
