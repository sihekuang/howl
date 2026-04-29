import Foundation

public protocol TextInjector: Sendable {
    func inject(_ text: String) async throws
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
