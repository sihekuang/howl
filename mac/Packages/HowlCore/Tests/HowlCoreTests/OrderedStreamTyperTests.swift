import Foundation
import Testing
@testable import HowlCore

/// Records every chunk it is asked to type, in arrival order. Yields
/// before recording so a typer that let chunks race would be caught
/// interleaving them.
private final class RecordingTyper: StreamingTextInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var _typed: [String] = []
    var typed: [String] { lock.withLock { _typed } }

    func injectChunk(_ text: String) async throws {
        await Task.yield()
        lock.withLock { _typed.append(text) }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool, timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("OrderedStreamTyper")
struct OrderedStreamTyperTests {

    // Regression: streamed LLM deltas were each typed from their own
    // unstructured Task, which Swift does not run in creation order, so
    // "the language model is scrambled" came out as "the model language
    // scrambled is".
    @Test func types_chunks_in_the_order_they_were_enqueued() async {
        let inner = RecordingTyper()
        let typer = OrderedStreamTyper(wrapping: inner)
        let chunks = (0..<500).map { " w\($0)" }

        for c in chunks { typer.enqueue(c) }

        #expect(await waitUntil { inner.typed.count == chunks.count }, "not every chunk was typed")
        #expect(inner.typed == chunks)
    }

    @Test func drops_empty_chunks() async {
        let inner = RecordingTyper()
        let typer = OrderedStreamTyper(wrapping: inner)

        typer.enqueue("")
        typer.enqueue("a")

        #expect(await waitUntil { inner.typed.count == 1 })
        #expect(inner.typed == ["a"])
    }
}
