import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("SecretStore")
struct SecretStoreTests {
    @Test func storeAndRetrieve() throws {
        let store = InMemorySecretStore()
        try store.setAPIKey("sk-ant-test", forProvider: "anthropic")
        #expect(try store.getAPIKey(forProvider: "anthropic") == "sk-ant-test")
    }

    @Test func deleteRemoves() throws {
        let store = InMemorySecretStore()
        try store.setAPIKey("sk-ant-x", forProvider: "anthropic")
        try store.deleteAPIKey(forProvider: "anthropic")
        #expect(try store.getAPIKey(forProvider: "anthropic") == nil)
    }

    @Test func emptyByDefault() throws {
        let store = InMemorySecretStore()
        #expect(try store.getAPIKey(forProvider: "anthropic") == nil)
    }

    @Test func providersHaveSeparateSlots() throws {
        let store = InMemorySecretStore()
        try store.setAPIKey("sk-ant-x", forProvider: "anthropic")
        try store.setAPIKey("sk-proj-y", forProvider: "openai")
        #expect(try store.getAPIKey(forProvider: "anthropic") == "sk-ant-x")
        #expect(try store.getAPIKey(forProvider: "openai") == "sk-proj-y")

        // Deleting one provider leaves the other intact.
        try store.deleteAPIKey(forProvider: "anthropic")
        #expect(try store.getAPIKey(forProvider: "anthropic") == nil)
        #expect(try store.getAPIKey(forProvider: "openai") == "sk-proj-y")
    }
}
