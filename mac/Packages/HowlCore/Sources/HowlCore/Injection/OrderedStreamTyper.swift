import Foundation

/// Types streamed chunks strictly in the order they were enqueued.
///
/// Streaming LLM deltas arrive in batches (the coordinator drains the
/// engine's event queue every 30 ms). Typing each one from its own
/// `Task { }` raced them: Swift does not run separately created tasks in
/// creation order, so adjacent deltas could land swapped ("the language
/// model is scrambled" → "the model language scrambled is"). Every chunk
/// here goes through one AsyncStream drained by a single task, so order
/// is preserved by construction.
public final class OrderedStreamTyper: Sendable {
    private let continuation: AsyncStream<String>.Continuation

    public init(wrapping inner: any StreamingTextInjector) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation
        Task {
            for await text in stream {
                try? await inner.injectChunk(text)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queues `text` to be typed after everything enqueued before it.
    /// Non-blocking; safe to call from any isolation.
    public func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        continuation.yield(text)
    }
}
