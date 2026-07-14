import SwiftUI

/// Phase 23 — the Vault browser, laid out as a photo-forward gallery.
///
/// Design principles (see the layout research): food is visual, so the
/// screen leads with photos (recognition over recall); each card has a
/// single focal path (photo → name → macros → tap-to-log); uniform cards
/// on a 2-column grid read as one curated collection (Gestalt); search
/// and sort appear only once the vault is large enough to need them
/// (progressive disclosure); the whole card is the log target (Fitts's
/// law) with remove tucked into a long-press (Hick's law).
///
/// Presented from `CaptureView.topBar` (the "Vault" pill). Tapping a card
/// re-logs the food into today — no photo, no AI, no scan credit — via
/// the same engine as Quick Re-log, sourced from the durable
/// `vault_items` table. `onPicked(item)` then dismiss; the parent
/// (`CaptureViewModel.relogFromVault`) owns the insert + success toast.
struct VaultSheet: View {
    /// Caller-provided re-log handler. The sheet dismisses itself right
    /// after invoking it; the network insert happens after dismissal.
    let onPicked: (SavedFood) -> Void
    /// "Add → Scan a new meal" — the parent (CaptureView) dismisses the vault
    /// and kicks off the scan flow. Nil hides the scan option.
    var onScanNew: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vault = VaultStore.shared

    @State private var query = ""
    @State private var sort: SortOrder = .recent
    /// Pushed meal-detail selection. Tapping a card opens the detail (it
    /// no longer logs on tap); the detail's "Log to today" button commits.
    @State private var selected: SavedFood?
    /// "Add meals" flow: the option dialog, then the pick-from-logs sheet.
    @State private var showingAddOptions = false
    @State private var showingPickFromLogs = false

    /// The search field is always available so the vault is searchable the
    /// moment it has foods (discoverability over minimalism). The sort menu
    /// is quieter and only earns its place once there's enough to reorder —
    /// it appears at/above this count.
    private static let sortThreshold = 6

    enum SortOrder: Hashable { case recent, name }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.tap()
                            showingAddOptions = true
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .foregroundStyle(Color.brandDeep)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.brandDeep)
                    }
                }
                .confirmationDialog("Add meals to your Vault",
                                    isPresented: $showingAddOptions,
                                    titleVisibility: .visible) {
                    if onScanNew != nil {
                        Button("Scan a new meal") {
                            onScanNew?()
                            dismiss()
                        }
                    }
                    Button("Pick from your logs") { showingPickFromLogs = true }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showingPickFromLogs) {
                    VaultAddFromLogsSheet()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .background(Color.bgCanvas)
                .navigationDestination(item: $selected) { item in
                    VaultMealDetailView(item: item) {
                        // Log to today, then close the whole sheet so the
                        // re-log toast lands on Home.
                        onPicked(item)
                        dismiss()
                    }
                }
                .task { await vault.loadIfNeeded() }
                // Debounced search + sort → the store filters against its
                // in-memory inverted index (zero egress) and re-pages. The
                // `id` restarts this task on each keystroke, so we only apply
                // after typing pauses instead of re-paging every character.
                .task(id: displayKey) {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled else { return }
                    vault.setDisplay(query: query, sortByName: sort == .name)
                }
        }
    }

    /// Restarts the debounce task whenever the query or sort changes.
    private var displayKey: String { "\(query)\u{1F}\(sort == .name ? "name" : "recent")" }

    @ViewBuilder
    private var content: some View {
        switch vault.loadState {
        case .idle, .loading:
            if vault.visible.isEmpty && vault.activeQuery.isEmpty {
                loadingState
            } else {
                gallery
            }
        case .failed(let message, let tableMissing):
            if vault.totalCount == 0 {
                failedState(message: message, tableMissing: tableMissing)
            } else {
                gallery
            }
        case .loaded:
            if vault.isEmpty {
                emptyState
            } else {
                gallery
            }
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                header
                searchAndSort
                galleryBody
            }
            .padding(.bottom, AppSpacing.xl2)
        }
    }

    /// The inner region below the search chrome: the grid, a "no matches"
    /// note, or a first-page spinner. Keeping this separate from the chrome
    /// means the search field stays put while results load or come up empty.
    @ViewBuilder
    private var galleryBody: some View {
        if !vault.visible.isEmpty {
            grid
        } else if !vault.activeQuery.isEmpty && vault.matchedCount == 0 {
            noResults
        } else {
            // Manifest is loaded but this order's first page is still fetching.
            ProgressView().tint(Color.brand)
                .frame(maxWidth: .infinity)
                .padding(.top, AppSpacing.xl2)
        }
    }

    private var noResults: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.inkLight)
            Text("No foods match \u{201C}\(vault.activeQuery)\u{201D}")
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.inkMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xl2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Your Vault")
                .appFont(.display2)
                .foregroundStyle(Color.brandDeep)
            Text(countLine)
                .appFont(.bodyEmphasis)
                .foregroundStyle(Color.brandDeep.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.brand, Color.brandBright],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        // Faint archive-box motif ties the header back to the entry pill.
        .overlay(alignment: .trailing) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(Color.brandDeep.opacity(0.10))
                .offset(x: 8)
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
    }

    private var countLine: String {
        let n = vault.totalCount
        return n == 1 ? "1 food you keep on hand"
                      : "\(n) foods you keep on hand"
    }

    private var searchAndSort: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkLight)
                TextField("Search foods", text: $query)
                    .font(AppFont.font(.bodyV2))
                    .foregroundStyle(Color.ink)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.inkLight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.bgSurface))
            .overlay(Capsule().strokeBorder(Color.borderHairline, lineWidth: 1))

            if vault.totalCount >= Self.sortThreshold {
                Menu {
                    Button { sort = .recent } label: {
                        Label("Recent", systemImage: sort == .recent ? "checkmark" : "clock")
                    }
                    Button { sort = .name } label: {
                        Label("A–Z", systemImage: sort == .name ? "checkmark" : "textformat")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .bold))
                        Text(sort == .recent ? "Recent" : "A–Z")
                            .appFont(.captionStrong)
                    }
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.bgSurface))
                    .overlay(Capsule().strokeBorder(Color.brand.opacity(0.30), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    private var grid: some View {
        let items = vault.visible
        return VStack(spacing: AppSpacing.md) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AppSpacing.md),
                    GridItem(.flexible(), spacing: AppSpacing.md)
                ],
                spacing: AppSpacing.md
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    VaultGridCard(
                        item: item,
                        index: idx,
                        onOpen: { selected = item },
                        onRemove: {
                            Task { await vault.remove(item.id) }
                        }
                    )
                    // Infinite scroll: when a card near the end appears, page
                    // in the next batch of cards (only the on-screen cards'
                    // heavy rows are ever fetched — the low-egress win).
                    .onAppear {
                        if idx >= items.count - 4 {
                            Task { await vault.loadNextPage() }
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            // Springy reflow so the remaining cards flow into the gap left by
            // a removed card.
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: items.count)

            if vault.canLoadMore {
                ProgressView()
                    .tint(Color.brand)
                    .padding(.vertical, AppSpacing.md)
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: AppSpacing.md) {
            ProgressView().tint(Color.brand)
            Text("Loading your vault…")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "archivebox")
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.brand)
            Text("Your vault is empty")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text("Save a food from the result screen, long-press a logged meal, or add one below. It'll live here for one-tap logging, forever.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)

            PrimaryButton(title: "Add a meal", leadingSystemImage: "plus") {
                Haptics.tap()
                showingAddOptions = true
            }
            .padding(.top, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.xl)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(message: String, tableMissing: Bool) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: tableMissing ? "wrench.and.screwdriver" : "exclamationmark.triangle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.error.opacity(0.85))
            Text(message)
                .appFont(.title1)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(tableMissing
                 ? "The vault needs a one-time database setup (migration 022) before it can store your foods."
                 : "Check your connection and try again.")
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
            if !tableMissing {
                PrimaryButton(title: "Try again",
                              leadingSystemImage: "arrow.clockwise") {
                    Task { await vault.reload() }
                }
                .padding(.top, AppSpacing.sm)
                .padding(.horizontal, AppSpacing.lg)
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One saved food in the gallery. Photo-first, single focal path:
/// photo (+ calorie chip) → name → quiet macro line. Tapping OPENS the
/// meal detail (it does not log on tap); a long-press removes it. Cards
/// fade-up on appear with a small index-based stagger.
private struct VaultGridCard: View {
    let item: SavedFood
    let index: Int
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var imageURL: URL?
    @State private var failed = false
    @State private var appeared = false
    /// Premium "dematerialize" remove: the card shrinks + blurs + drifts up +
    /// fades while it bursts into brand particles, reading as it vanishing
    /// into dust. `vanishStart` triggers the particle Canvas; `onRemove`
    /// fires once it's gone so the grid reflow happens with the card already
    /// invisible and the neighbors spring cleanly into the gap.
    @State private var isVanishing = false
    @State private var vanishStart: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let imageService = FoodImageService()
    private static let vanishDuration: Double = 0.6
    private static let photoHeight: CGFloat = 120
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                photo
                info
            }
            .background(shape.fill(Color.bgSurface))
            .overlay(shape.strokeBorder(Color.borderHairline, lineWidth: 1))
            .clipShape(shape)
            .appShadow(.shadowCard)
            .contentShape(shape)
        }
        .buttonStyle(MorphingPressStyle(scale: 0.97))
        .contextMenu {
            Button(role: .destructive, action: runRemove) {
                Label("Remove from Vault", systemImage: "bookmark.slash")
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        // Dematerialize the card. These transforms affect ONLY the card…
        .scaleEffect(isVanishing ? 0.82 : 1)
        .blur(radius: isVanishing ? 12 : 0)
        .offset(y: isVanishing ? -14 : 0)
        .opacity(isVanishing ? 0 : 1)
        // …and the particle burst is layered AFTER, so the escaping dust is
        // not itself blurred or faded with the card.
        .overlay {
            if let vanishStart {
                VanishParticles(start: vanishStart, duration: Self.vanishDuration)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(!isVanishing)
        .task { await loadThumbnail() }
        .onAppear(perform: animateIn)
        .accessibilityLabel("\(item.foodName), \(macroLine)")
        .accessibilityHint("Opens the meal details")
    }

    // MARK: - Remove choreography

    private func runRemove() {
        guard !isVanishing else { return }
        guard !reduceMotion else { onRemove(); return }
        Haptics.soft()
        vanishStart = Date()
        // The card shrinks/blurs/fades over a hair less than the particle
        // lifetime, so it's gone before the last of the dust settles.
        withAnimation(.easeOut(duration: 0.46)) { isVanishing = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.vanishDuration * 1_000_000_000))
            onRemove()
        }
    }

    // MARK: - Photo

    private var photo: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: Self.photoHeight)
                .clipped()

            calorieChip
                .padding(AppSpacing.sm)
        }
        .frame(height: Self.photoHeight)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:                placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// Photoless items (manual saves) get a warm branded tile with the
    /// food's initial, so the grid stays uniform and legible.
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.brandSoft, Color.brandCream],
                startPoint: .top, endPoint: .bottom
            )
            Text(initial)
                .appFont(.display2)
                .foregroundStyle(Color.brand.opacity(0.65))
        }
    }

    private var initial: String {
        let trimmed = item.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    /// Dark-olive pill, always legible on any photo (a frosted material
    /// would wash out over bright dishes).
    private var calorieChip: some View {
        Text("\(format(item.calories)) cal")
            .appFont(.captionStrong)
            .foregroundStyle(Color.brandCream)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.brandDeep.opacity(0.88)))
    }

    // MARK: - Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.foodName)
                .appFont(.title2)
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(macroLine)
                .appFont(.caption)
                .foregroundStyle(Color.inkMute)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// Quiet, two-macro line (carbs + protein when present). Calories
    /// already live in the photo chip, so they're omitted here.
    private var macroLine: String {
        var parts = ["\(format(item.carbsG))g carbs"]
        if let p = item.proteinG { parts.append("\(format(p))g protein") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Behavior

    private func animateIn() {
        guard !appeared else { return }
        guard !reduceMotion else { appeared = true; return }
        // Cap the stagger so a big vault doesn't crawl in.
        let delay = Double(min(index, 8)) * 0.045
        withAnimation(.easeOut(duration: 0.32).delay(delay)) {
            appeared = true
        }
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "-" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }

    private func loadThumbnail() async {
        guard imageURL == nil, !failed else { return }
        let path: String? = item.imageThumbPath ?? item.imagePath
        guard let path, !path.isEmpty else { return }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: path)
            await MainActor.run { self.imageURL = url }
        } catch {
            await MainActor.run { self.failed = true }
        }
    }
}

/// Vault meal detail — pushed when a gallery card is tapped. Shows the
/// full saved analysis (photo, calories, the six-macro grid, the AI coach
/// note, and the benefits/drawbacks/nutrients breakdown) with a sticky
/// "Log to today" button. Reuses the app's meal components via
/// `SavedFood.asFoodLog` so the breakdown reads exactly like a logged
/// meal's expansion, no logging happens until the user taps Log.
private struct VaultMealDetailView: View {
    let item: SavedFood
    let onLog: () -> Void

    @State private var imageURL: URL?
    @State private var failed = false
    private static let imageService = FoodImageService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                hero
                Text(item.foodName)
                    .appFont(.display2)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, AppSpacing.lg)

                MealMacroGrid(log: item.asFoodLog)
                    .padding(.horizontal, AppSpacing.lg)

                coach
                breakdown
            }
            .padding(.top, AppSpacing.md)
            // Clear the sticky Log bar so the last accordion is never
            // stuck behind it (taps there would hit the bar).
            .padding(.bottom, AppSpacing.xl2)
        }
        .background(Color.bgCanvas)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { logBar }
        .task { await loadImage() }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            heroImage
                .frame(maxWidth: .infinity)
                .frame(height: 188)
                .clipped()
            calorieChip
                .padding(AppSpacing.md)
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Color.borderHairline, lineWidth: 1)
        )
        .padding(.horizontal, AppSpacing.lg)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:                heroPlaceholder
                }
            }
        } else {
            heroPlaceholder
        }
    }

    private var heroPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.brandSoft, Color.brandCream],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "fork.knife")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.brand.opacity(0.55))
        }
    }

    private var calorieChip: some View {
        Text("\(format(item.calories)) cal")
            .appFont(.captionStrong)
            .foregroundStyle(Color.brandCream)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.brandDeep.opacity(0.88)))
    }

    // MARK: - Coach

    @ViewBuilder
    private var coach: some View {
        if let advice = item.coachAdvice, !advice.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Coach").eyebrow()
                    .foregroundStyle(Color.inkLight)
                EditorialQuote(text: advice, attribution: item.coachName)
            }
            .padding(.horizontal, AppSpacing.lg)
        }
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdown: some View {
        let hasAny = !item.nutrients.isEmpty || !item.benefits.isEmpty || !item.drawbacks.isEmpty
        if hasAny {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Breakdown").eyebrow()
                    .foregroundStyle(Color.inkLight)
                // This is a "review the meal" screen, so the breakdown
                // opens expanded (the user came here to read it). Each
                // accordion still toggles on tap — box or chevron.
                if !item.nutrients.isEmpty {
                    CategoryAccordion(kind: .nutrients, title: "Nutrients",
                                      items: item.nutrients, startsExpanded: true)
                }
                if !item.benefits.isEmpty {
                    CategoryAccordion(kind: .benefits, title: "Benefits",
                                      items: item.benefits, startsExpanded: true)
                }
                if !item.drawbacks.isEmpty {
                    CategoryAccordion(kind: .drawbacks, title: "Drawbacks",
                                      items: item.drawbacks, startsExpanded: true)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
        }
    }

    // MARK: - Log bar

    private var logBar: some View {
        PrimaryButton(title: "Log to today",
                      leadingSystemImage: "checkmark.circle.fill") {
            Haptics.success()
            onLog()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            Color.bgCanvas
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.borderHairline).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "-" }
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.1f", v)
    }

    private func loadImage() async {
        guard imageURL == nil, !failed else { return }
        // Prefer the full image for the large hero; fall back to the thumb.
        let path: String? = item.imagePath ?? item.imageThumbPath
        guard let path, !path.isEmpty else { return }
        do {
            let url = try await Self.imageService.cachedSignedURL(for: path)
            await MainActor.run { self.imageURL = url }
        } catch {
            await MainActor.run { self.failed = true }
        }
    }
}

/// The brand-colored "dust" a vault card bursts into as it dematerializes.
/// One `Canvas` driven by a per-frame `TimelineView` (the same engine as the
/// analyzing orb) — particles scatter outward with an upward bias, then
/// gravity pulls them down as they shrink and fade. Params are derived
/// deterministically from the particle index so they stay put across frames
/// (no `Math.random` re-rolling every tick). Self-contained: it plays once
/// from `start` over `duration`.
private struct VanishParticles: View {
    let start: Date
    let duration: Double

    private let count = 30
    private let colors: [Color] = [.brand, .brandBright, .brandDeep, .brandSoft]

    var body: some View {
        TimelineView(.animation) { tl in
            let raw = tl.date.timeIntervalSince(start) / max(0.01, duration)
            let t = CGFloat(min(1, max(0, raw)))
            Canvas { ctx, size in
                guard t < 1 else { return }
                let cx = size.width / 2
                let cy = size.height * 0.42            // burst near the photo
                let ease = 1 - pow(1 - t, 2)           // ease-out spread
                for i in 0..<count {
                    let r1 = Self.rand(i, 1)
                    let r2 = Self.rand(i, 2)
                    let r3 = Self.rand(i, 3)
                    let angle = r1 * 2 * .pi
                    let speed = 36 + r2 * 90
                    let dx = cos(angle) * speed * ease
                    // Up first, then gravity pulls the dust back down.
                    let dy = sin(angle) * speed * ease - 44 * ease + 130 * t * t
                    let sz = (3 + r3 * 5) * (1 - t * 0.6)
                    guard sz > 0.3 else { continue }
                    let rect = CGRect(x: cx + dx - sz / 2, y: cy + dy - sz / 2,
                                      width: sz, height: sz)
                    let color = colors[i % colors.count]
                    ctx.drawLayer { layer in
                        layer.opacity = Double(1 - t)
                        layer.fill(
                            Path(roundedRect: rect, cornerRadius: sz * 0.3),
                            with: .color(color)
                        )
                    }
                }
            }
        }
    }

    /// Stable [0,1) pseudo-random from (index, salt) — a hashed fract(sin).
    private static func rand(_ i: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(i) * 127.1 + Double(salt) * 311.7) * 43758.5453
        return CGFloat(x - floor(x))
    }
}

/// "Add → Pick from your logs": a list of the user's recent unique meals;
/// tapping one snapshots it into the Vault (`VaultStore.add(from:)`, zero
/// upload — the photo is shared). Stays open so several can be added in a
/// row; rows already in the vault read "In Vault".
private struct VaultAddFromLogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vault = VaultStore.shared
    @State private var state: LoadState = .loading
    private let history = MealHistoryService()

    enum LoadState {
        case loading
        case empty
        case loaded([FoodLog])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pick from logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundStyle(Color.brandDeep)
                    }
                }
                .background(Color.bgCanvas)
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().tint(Color.brand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            emptyState
        case .failed(let message):
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.error.opacity(0.85))
                Text(message)
                    .appFont(.caption)
                    .foregroundStyle(Color.inkMute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let logs):
            ScrollView {
                VStack(spacing: AppSpacing.md) {
                    ForEach(logs) { log in
                        VaultAddLogRow(log: log)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(Color.inkLight)
            Text("No meals logged yet")
                .appFont(.title1)
                .foregroundStyle(Color.ink)
            Text("Once you log some meals, they'll show up here to add to your vault.")
                .appFont(.bodyV2)
                .foregroundStyle(Color.inkMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        state = .loading
        do {
            let logs = try await history.recentUniqueMeals(limit: 30)
            state = logs.isEmpty ? .empty : .loaded(logs)
        } catch {
            state = .failed("Couldn't load your meals.")
        }
    }
}

/// One recent-meal row in the pick-from-logs sheet. Tapping adds it to the
/// vault; the trailing chip flips to "In Vault" once it's saved.
private struct VaultAddLogRow: View {
    let log: FoodLog

    @StateObject private var vault = VaultStore.shared
    @State private var imageURL: URL?
    @State private var failed = false
    @State private var adding = false
    private static let imageService = FoodImageService()

    private var inVault: Bool { vault.isInVault(foodName: log.foodName) }

    var body: some View {
        Button(action: add) {
            HStack(spacing: AppSpacing.md) {
                thumbnail
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .strokeBorder(Color.borderHairline, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.foodName)
                        .appFont(.title2)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(macroLine)
                        .appFont(.caption)
                        .foregroundStyle(Color.inkMute)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                addChip
            }
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.sm + 2)
            .frame(minHeight: 72)
            .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.bgSurface))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(Color.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(MorphingPressStyle(scale: 0.98))
        .disabled(inVault || adding)
        .appShadow(.shadowCard)
        .task { await loadThumbnail() }
        .accessibilityLabel("\(log.foodName), \(macroLine)")
        .accessibilityHint(inVault ? "Already in your vault" : "Adds this meal to your vault")
    }

    private var addChip: some View {
        HStack(spacing: 4) {
            Image(systemName: inVault ? "bookmark.fill" : "plus")
                .font(.system(size: 12, weight: .bold))
            Text(inVault ? "In Vault" : "Add")
                .appFont(.captionStrong)
        }
        .foregroundStyle(inVault ? Color.brandDeep : Color.brand)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(inVault ? Color.brandSoft : Color.bgSurface)
        )
        .overlay(
            Capsule().strokeBorder(
                inVault ? Color.brandDeep.opacity(0.3) : Color.brand.opacity(0.5),
                lineWidth: 1
            )
        )
    }

    private func add() {
        guard !inVault, !adding else { return }
        adding = true
        Haptics.success()
        Task {
            _ = await vault.add(from: log)
            adding = false
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:                placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.bgSurfaceSoft
            Image(systemName: failed ? "photo.badge.exclamationmark" : "fork.knife")
                .font(.system(size: 16))
                .foregroundStyle(Color.inkLight)
        }
    }

    private var macroLine: String {
        var parts = ["\(format(log.calories)) cal", "\(format(log.carbsG))g carbs"]
        if let p = log.proteinG { parts.append("\(format(p))g protein") }
        return parts.joined(separator: " · ")
    }

    private func format(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "-" }
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
            await MainActor.run { self.failed = true }
        }
    }
}
