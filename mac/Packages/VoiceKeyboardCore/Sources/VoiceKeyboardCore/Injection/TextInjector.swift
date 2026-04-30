import Foundation

public protocol TextInjector: Sendable {
    func inject(_ text: String) async throws
}

/// A TextInjector that supports streaming: characters can be typed at
/// the cursor as they arrive (e.g. from an LLM streaming API) instead
/// of waiting for the full text to land. `injectChunk` is called
/// repeatedly with each delta; nothing else is needed at the end —
/// the cursor position naturally tracks what's already typed.
public protocol StreamingTextInjector: Sendable {
    func injectChunk(_ text: String) async throws
}

/// Tiny abstraction over NSPasteboard so we can fake it in tests.
public protocol PasteboardProtocol: Sendable {
    func string() async -> String?
    func setString(_ s: String) async
    func clear() async
}

/// Tiny abstraction over CGEventPost so we can fake it in tests.
public protocol KeystrokeSenderProtocol: Sendable {
    func sendCmdV() async
}
