import Foundation

/// Drives the analysis-panel typewriter effect.
/// Renders an array of strings one character at a time, advancing to the
/// next item only after the current one finishes. 20ms/char per spec.
@MainActor
final class TypewriterController: ObservableObject {
    @Published private(set) var displayedText: [String]
    @Published private(set) var isDone: Bool = false

    private(set) var items: [String]
    let perCharSeconds: TimeInterval
    private var task: Task<Void, Never>?

    init(items: [String], perCharSeconds: TimeInterval = 0.02) {
        self.items = items
        self.perCharSeconds = perCharSeconds
        self.displayedText = items.map { _ in "" }
    }

    /// Reset and rewind. Does not start typing.
    func reset(items newItems: [String]? = nil) {
        task?.cancel()
        if let newItems { self.items = newItems }
        self.displayedText = self.items.map { _ in "" }
        self.isDone = false
    }

    /// Begin typing from current position. Idempotent — calling twice while
    /// already typing has no effect.
    ///
    /// The character loop snapshots `items` and `perCharSeconds` at start
    /// time and uses a *weak* self reference inside each character write,
    /// so the controller is not held alive by its own stored Task for the
    /// duration of a long quote. A long typewriter doesn't pin the
    /// controller across navigation/state changes — the next user
    /// interaction can release it immediately.
    func start() {
        guard task == nil || task?.isCancelled == true else { return }
        guard !isDone else { return }
        let snapshotItems = items
        let snapshotPerChar = perCharSeconds
        task = Task { [weak self] in
            // Read the prefix counts once up front so the loop body
            // doesn't have to keep dereferencing self for read-only
            // bookkeeping.
            let initialPrefix: [Int] = await MainActor.run { [weak self] in
                guard let self else { return [] }
                return snapshotItems.enumerated().map { idx, _ in
                    self.displayedText.indices.contains(idx)
                        ? self.displayedText[idx].count
                        : 0
                }
            }
            guard !initialPrefix.isEmpty else { return }

            for (idx, item) in snapshotItems.enumerated() {
                let already = idx < initialPrefix.count ? initialPrefix[idx] : 0
                let chars = Array(item)
                guard already < chars.count else { continue }
                for cIdx in already..<chars.count {
                    if Task.isCancelled { return }
                    let nextChar = chars[cIdx]
                    // Strong reference is scoped to this block only —
                    // released before the next Task.sleep suspension,
                    // so the controller can deinit mid-loop if needed.
                    if let strong = self {
                        guard idx < strong.displayedText.count else { return }
                        strong.displayedText[idx].append(nextChar)
                    } else {
                        return
                    }
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(snapshotPerChar * 1_000_000_000)
                        )
                    } catch {
                        return
                    }
                }
            }
            if let strong = self { strong.isDone = true }
        }
    }

    deinit { task?.cancel() }
}
