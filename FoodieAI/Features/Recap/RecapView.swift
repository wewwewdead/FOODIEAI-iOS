import SwiftUI

/// Phase 17. Magazine-style weekly recap.
///
/// Layout:
///   1. Eyebrow "WEEK OF" + date range
///   2. Hero collage: 3-4 thumbnails arranged asymmetrically. Selection
///      rule (deterministic): highest-calorie meals first, ties broken
///      by most-recent eaten_at. Documented in the verification doc.
///   3. Headline stat (display2): "23 meals"
///   4. Subhead with calorie totals from `headline_stat`
///   5. EditorialQuote with the coach's body
///   6. Top-pattern card (or hidden when null)
///   7. "View this week's meals" expander → list of meals
///   8. "Past recaps" link → history view
///
/// Two entry points (per the brief, picking minimal):
///   - Notification deep link (router in FoodieAIApp)
///   - "This week" affordance on TodayView
///
/// Don't auto-open on launch. The user came in for something else.
struct RecapView: View {
    let recap: WeeklyRecap
    var onClose: (() -> Void)? = nil

    @StateObject private var vm = RecapDetailViewModel()
    @State private var showingMeals = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl2) {
                eyebrow
                heroCollage
                headlineBlock
                moodSummaryBlock
                quoteBlock
                topPatternBlock
                mealsExpander
                pastRecapsLink
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas)
        .navigationTitle("Weekly recap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await vm.loadMeals(for: recap)
        }
    }

    // MARK: - Eyebrow

    private var eyebrow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Week of").eyebrow()
                .foregroundStyle(Color.inkMute)
            Text(rangeString(recap.weekStart, recap.weekEnd))
                .appFont(.display2)
                .foregroundStyle(Color.ink)
        }
    }

    // MARK: - Hero collage

    @ViewBuilder
    private var heroCollage: some View {
        switch vm.state {
        case .loading:
            collageSkeleton
        case .loaded(let meals):
            if let collage = Self.collageMeals(meals) {
                CollageGrid(meals: collage)
            } else {
                collageEmpty
            }
        case .failed:
            collageEmpty
        }
    }

    private var collageSkeleton: some View {
        RoundedRectangle(cornerRadius: AppRadius.xl)
            .fill(Color.bgSurfaceSoft)
            .frame(height: 220)
    }

    private var collageEmpty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(Color.bgSurfaceSoft)
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.inkLight)
                Text("No meal photos this week")
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
        }
        .frame(height: 220)
    }

    // MARK: - Headline

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let head = recap.headlineStat {
                let parts = head.split(separator: "·", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                Text(parts.first ?? head)
                    .appFont(.display1)
                    .foregroundStyle(Color.ink)
                if parts.count == 2 {
                    Text(parts[1])
                        .appFont(.bodyV2)
                        .foregroundStyle(Color.inkMute)
                }
            }
        }
    }

    // MARK: - Mood summary (Phase 18)

    @ViewBuilder
    private var moodSummaryBlock: some View {
        if let summary = recap.moodSummary, !summary.isEmpty {
            Text(summary)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Mood summary: \(summary)")
        }
    }

    // MARK: - Quote

    private var quoteBlock: some View {
        EditorialQuote(
            text: recap.body,
            attribution: recap.coachName,
            typewriter: false
        )
    }

    // MARK: - Top pattern

    @ViewBuilder
    private var topPatternBlock: some View {
        if let top = recap.topPattern, !top.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Top pattern").eyebrow()
                    .foregroundStyle(Color.inkMute)
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 24, height: 24)
                    Text(top)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(Color.borderHairline, lineWidth: 1)
                )
                .appShadow(.shadowCard)
            }
        }
    }

    // MARK: - Meals expander

    @ViewBuilder
    private var mealsExpander: some View {
        if case .loaded(let meals) = vm.state, !meals.isEmpty {
            DisclosureGroup(isExpanded: $showingMeals) {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(meals) { log in
                        MealCard(log: log, onTap: {})
                    }
                }
                .padding(.top, AppSpacing.sm)
            } label: {
                HStack {
                    Text("View this week's meals")
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(Color.brandDeep)
                    Spacer()
                    Text("\(meals.count)")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.inkMute)
                }
            }
            .tint(Color.brandDeep)
        }
    }

    // MARK: - Past recaps

    private var pastRecapsLink: some View {
        NavigationLink {
            PastRecapsView()
        } label: {
            HStack(spacing: 6) {
                Text("Past recaps")
                    .appFont(.captionStrong)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(Color.brandDeep)
        }
        .buttonStyle(.plain)
        .padding(.top, AppSpacing.lg)
    }

    // MARK: - Helpers

    private func rangeString(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return "\(f.string(from: start)) — \(f.string(from: end))"
    }

    /// Pick up to 4 collage meals. Rule: highest-calorie first, ties
    /// broken by most-recent `eatenAt`. Filter out meals with no
    /// thumb/main image. Documented in the verification report.
    static func collageMeals(_ meals: [FoodLog]) -> [FoodLog]? {
        let withImage = meals.filter {
            ($0.imageThumbPath?.isEmpty == false) || ($0.imagePath?.isEmpty == false)
        }
        guard !withImage.isEmpty else { return nil }
        let sorted = withImage.sorted { a, b in
            if a.calories != b.calories { return a.calories > b.calories }
            return a.eatenAt > b.eatenAt
        }
        return Array(sorted.prefix(4))
    }
}

// MARK: - Collage grid

/// Phase 17. Asymmetric 4-photo arrangement. With 1 image: full-width
/// card. With 2: side-by-side. With 3: a tall left + two stacked
/// right. With 4: the same 3-arrangement plus a small inset.
private struct CollageGrid: View {
    let meals: [FoodLog]

    var body: some View {
        Group {
            switch meals.count {
            case 0: EmptyView()
            case 1: single
            case 2: pair
            case 3: trio
            default: quad
            }
        }
        .frame(height: 220)
    }

    private var single: some View {
        thumb(meals[0])
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
    }

    private var pair: some View {
        HStack(spacing: AppSpacing.sm) {
            thumb(meals[0])
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
            thumb(meals[1])
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
        }
    }

    private var trio: some View {
        HStack(spacing: AppSpacing.sm) {
            thumb(meals[0])
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                .frame(maxWidth: .infinity)
            VStack(spacing: AppSpacing.sm) {
                thumb(meals[1])
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                thumb(meals[2])
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var quad: some View {
        HStack(spacing: AppSpacing.sm) {
            // Left: tallest hero
            thumb(meals[0])
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                .frame(maxWidth: .infinity)
            VStack(spacing: AppSpacing.sm) {
                thumb(meals[1])
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                HStack(spacing: AppSpacing.sm) {
                    thumb(meals[2])
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    thumb(meals[3])
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func thumb(_ log: FoodLog) -> some View {
        CollageThumbnail(log: log)
    }
}

/// Phase 17. Async-loaded thumbnail from Supabase Storage. Reuses the
/// same `FoodImageService.cachedSignedURL` path as `MealCard`.
private struct CollageThumbnail: View {
    let log: FoodLog
    @State private var url: URL?

    private static let imageService = FoodImageService()

    var body: some View {
        ZStack {
            Color.bgSurfaceSoft
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color.inkLight)
                    }
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.inkLight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private func load() async {
        guard url == nil else { return }
        let path = log.imageThumbPath ?? log.imagePath
        guard let path, !path.isEmpty else { return }
        if let signed = try? await Self.imageService.cachedSignedURL(for: path) {
            await MainActor.run { self.url = signed }
        }
    }
}

// MARK: - Detail view model

@MainActor
final class RecapDetailViewModel: ObservableObject {
    enum State {
        case loading
        case loaded([FoodLog])
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    private let logService: FoodLogService

    init(logService: FoodLogService = FoodLogService()) {
        self.logService = logService
    }

    func loadMeals(for recap: WeeklyRecap) async {
        state = .loading
        // Half-open range: weekStart..<weekEnd+1.
        let weekEndExclusive = Calendar.current.date(
            byAdding: .day, value: 1, to: recap.weekEnd
        ) ?? recap.weekEnd
        do {
            let logs = try await logService.logs(
                from: recap.weekStart, to: weekEndExclusive
            )
            state = .loaded(logs)
        } catch {
            state = .failed(error)
        }
    }
}

// MARK: - Past recaps

/// Phase 17. Lightweight history list. Each row is a recap card with
/// the date range + headline stat; tap pushes a fresh `RecapView`.
struct PastRecapsView: View {
    @StateObject private var vm = PastRecapsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                switch vm.state {
                case .loading:
                    ProgressView().tint(Color.brand)
                        .padding(AppSpacing.xl)
                case .empty:
                    AmbientEmptyState(
                        iconSystemName: "calendar",
                        message: "No past recaps yet."
                    )
                case .loaded(let recaps):
                    ForEach(recaps) { recap in
                        NavigationLink {
                            RecapView(recap: recap)
                        } label: {
                            row(recap)
                        }
                        .buttonStyle(.plain)
                    }
                case .failed(let err):
                    Text(err.localizedDescription)
                        .appFont(.caption)
                        .foregroundStyle(Color.error)
                        .padding(AppSpacing.lg)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl3)
        }
        .background(Color.bgCanvas)
        .navigationTitle("Past recaps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await vm.load() }
    }

    private func row(_ recap: WeeklyRecap) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(rangeString(recap.weekStart, recap.weekEnd))
                .appFont(.title2)
                .foregroundStyle(Color.ink)
            if let stat = recap.headlineStat {
                Text(stat)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            Text(recap.coachName)
                .appFont(.captionStrong)
                .foregroundStyle(Color.brandDeep)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
    }

    private func rangeString(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d"
        return "\(f.string(from: start)) — \(f.string(from: end))"
    }
}

@MainActor
final class PastRecapsViewModel: ObservableObject {
    enum State {
        case loading
        case empty
        case loaded([WeeklyRecap])
        case failed(Error)
    }

    @Published private(set) var state: State = .loading

    private let service: WeeklyRecapService

    init(service: WeeklyRecapService = WeeklyRecapService()) {
        self.service = service
    }

    func load() async {
        state = .loading
        do {
            let rows = try await service.history()
            state = rows.isEmpty ? .empty : .loaded(rows)
        } catch {
            state = .failed(error)
        }
    }
}
