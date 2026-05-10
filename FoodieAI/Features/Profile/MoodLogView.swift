import SwiftUI

/// Phase 18 — read-only-ish list of the user's mood-labeled meals
/// from the last 30 days. Filterable by mood (loved / fine / tough).
/// Tapping a row opens the same `MoodPulseSheet` as the post-save
/// pulse so the user can change or clear their answer.
///
/// This is the mood data made visible to the user — without it, mood
/// recording feels like a black hole users tap into without seeing
/// where it goes. v1 keeps it deliberately simple: no charts, no
/// "your week emotionally" dashboard. Just the rows.
struct MoodLogView: View {
    @StateObject private var vm = MoodLogViewModel()
    @State private var editingLog: FoodLog? = nil

    var body: some View {
        ZStack {
            Color.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    filterChips
                    content
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl3)
            }
        }
        .navigationTitle("Mood log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await vm.load() }
        .sheet(item: $editingLog) { log in
            MoodPulseSheet(
                onPick: { mood in
                    Task {
                        await vm.setMood(mood, on: log.id)
                        editingLog = nil
                    }
                },
                onSkip: {
                    Task {
                        // Skip on an existing-mood row clears the label.
                        await vm.setMood(nil, on: log.id)
                        editingLog = nil
                    }
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(FoodLog.Mood.allCases, id: \.self) { mood in
                chip(mood: mood)
            }
            if vm.filter != nil {
                Button {
                    Haptics.tap()
                    Task { await vm.setFilter(nil) }
                } label: {
                    Text("Clear")
                        .appFont(.captionStrong)
                        .foregroundStyle(Color.brandDeep)
                        .padding(.horizontal, AppSpacing.sm)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(mood: FoodLog.Mood) -> some View {
        let isOn = vm.filter == mood
        return Button {
            Haptics.tap()
            Task { await vm.setFilter(isOn ? nil : mood) }
        } label: {
            HStack(spacing: 6) {
                Text(mood.emoji)
                    .font(.system(size: 16))
                Text(mood.label)
                    .appFont(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isOn ? Color.brandSoft : Color.bgSurface)
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn ? Color.brandDeep : Color.borderHairline,
                    lineWidth: isOn ? 2 : 1
                )
            )
            .foregroundStyle(isOn ? Color.brandDeep : Color.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mood.label) filter")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            ProgressView()
                .controlSize(.regular)
                .tint(Color.brand)
                .frame(maxWidth: .infinity)
                .padding(AppSpacing.xl)
        case .empty:
            emptyView
        case .loaded(let logs):
            VStack(spacing: AppSpacing.sm) {
                ForEach(logs) { log in
                    Button {
                        Haptics.tap()
                        editingLog = log
                    } label: {
                        MoodLogRow(log: log)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .failed(let err):
            Text(err.localizedDescription)
                .appFont(.caption)
                .foregroundStyle(Color.error)
                .padding(AppSpacing.lg)
        }
    }

    private var emptyView: some View {
        VStack(spacing: AppSpacing.sm) {
            Text(vm.filter == nil
                 ? "No mood-labeled meals yet."
                 : "No meals match this mood in the last 30 days.")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
            Text(vm.filter == nil
                 ? "After you save a meal, you'll be asked how it hit."
                 : "Try another filter.")
                .appFont(.caption)
                .foregroundStyle(Color.inkLight)
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct MoodLogRow: View {
    let log: FoodLog
    @State private var thumbURL: URL? = nil

    private static let imageService = FoodImageService()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            thumb
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(log.foodName)
                    .appFont(.bodyEmphasis)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(Self.dateFormatter.string(from: log.eatenAt))
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let mood = log.mood {
                Text(mood.emoji)
                    .font(.system(size: 28))
                    .accessibilityLabel(mood.label)
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .task { await loadThumb() }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            Color.bgSurfaceSoft
            if let thumbURL {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Image(systemName: "photo")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.inkLight)
                    }
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.inkLight)
            }
        }
    }

    private func loadThumb() async {
        guard thumbURL == nil else { return }
        let path = log.imageThumbPath ?? log.imagePath
        guard let path, !path.isEmpty else { return }
        if let signed = try? await Self.imageService.cachedSignedURL(for: path) {
            await MainActor.run { self.thumbURL = signed }
        }
    }
}

// MARK: - View model

@MainActor
final class MoodLogViewModel: ObservableObject {
    enum State {
        case loading
        case empty
        case loaded([FoodLog])
        case failed(Error)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var filter: FoodLog.Mood? = nil

    private let history: MealHistoryService
    private let logService: FoodLogService

    init(history: MealHistoryService = MealHistoryService(),
         logService: FoodLogService = FoodLogService()) {
        self.history = history
        self.logService = logService
    }

    func load() async {
        state = .loading
        do {
            let rows = try await history.moodLog(filter: filter)
            state = rows.isEmpty ? .empty : .loaded(rows)
        } catch {
            state = .failed(error)
        }
    }

    func setFilter(_ newFilter: FoodLog.Mood?) async {
        filter = newFilter
        await load()
    }

    /// Edit-on-tap path. Persists the new mood (or `nil` to clear) and
    /// reloads from the server so the visible list always matches
    /// what's stored. Reload is cheap on a single user's 30-day mood
    /// slice and avoids the encoding-strategy gymnastics that
    /// in-place mutation would require for `FoodLog`'s many `let`
    /// properties.
    func setMood(_ mood: FoodLog.Mood?, on logId: UUID) async {
        do {
            _ = try await logService.setMood(mood, on: logId)
        } catch {
            #if DEBUG
            NSLog("[MoodLog] setMood FAILED log=%@ err=%@",
                  logId.uuidString, "\(error)")
            #endif
        }
        await load()
    }
}

#if DEBUG
#Preview("MoodLogView") {
    NavigationStack { MoodLogView() }
}
#endif
