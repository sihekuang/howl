import Foundation
import Testing
@testable import VoiceKeyboardCore

actor SpyPasteboard: PasteboardProtocol {
    var contents: [String: String] = [:]
    func string() -> String? { contents["string"] }
    func setString(_ s: String) { contents["string"] = s }
    func clear() { contents.removeAll() }
}

actor SpyKeystrokeSender: KeystrokeSenderProtocol {
    var sent: [(keyCode: UInt16, modifiers: ModifierFlags)] = []
    func sendCmdV() {
        sent.append((keyCode: 9, modifiers: [.command]))
    }
}

@Suite("ClipboardPasteInjector")
struct ClipboardPasteInjectorTests {
    @Test func savesRestoresAndPastes() async throws {
        let pb = SpyPasteboard()
        await pb.setString("user-prior-clipboard")
        let ks = SpyKeystrokeSender()
        let inj = ClipboardPasteInjector(pasteboard: pb, keystroke: ks, restoreDelay: 0.001)

        try await inj.inject("Cleaned text.")

        let sent = await ks.sent
        #expect(sent.count == 1)
        let restored = await pb.string()
        #expect(restored == "user-prior-clipboard")
    }

    @Test func emptyTextNoOp() async throws {
        let pb = SpyPasteboard()
        await pb.setString("preserved")
        let ks = SpyKeystrokeSender()
        let inj = ClipboardPasteInjector(pasteboard: pb, keystroke: ks, restoreDelay: 0.001)

        try await inj.inject("")

        let sent = await ks.sent
        #expect(sent.isEmpty)
        #expect(await pb.string() == "preserved")
    }
}
