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
    func start() {
        guard task == nil || task?.isCancelled == true else { return }
        guard !isDone else { return }
        task = Task { [weak self] in
            guard let self else { return }
            for (idx, item) in items.enumerated() {
                // Skip already-displayed prefix (in case of mid-typing pause).
                let already = displayedText.indices.contains(idx) ? displayedText[idx].count : 0
                let chars = Array(item)
                guard already < chars.count else { continue }
                for cIdx in already..<chars.count {
                    if Task.isCancelled { return }
                    displayedText[idx].append(chars[cIdx])
                    try? await Task.sleep(nanoseconds: UInt64(perCharSeconds * 1_000_000_000))
                }
            }
            isDone = true
        }
    }

    deinit { task?.cancel() }
}
