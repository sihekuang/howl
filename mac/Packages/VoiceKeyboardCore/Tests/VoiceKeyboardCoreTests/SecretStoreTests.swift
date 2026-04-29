import Foundation
import Testing
@testable import VoiceKeyboardCore

@Suite("SecretStore")
struct SecretStoreTests {
    @Test func storeAndRetrieve() throws {
        let store = InMemorySecretStore()
        try store.setAPIKey("sk-ant-test")
        #expect(try store.getAPIKey() == "sk-ant-test")
    }

    @Test func deleteRemoves() throws {
        let store = InMemorySecretStore()
        try store.setAPIKey("sk-ant-x")
        try store.deleteAPIKey()
        #expect(try store.getAPIKey() == nil)
    }

    @Test func emptyByDefault() throws {
        let store = InMemorySecretStore()
        #expect(try store.getAPIKey() == nil)
    }
}
