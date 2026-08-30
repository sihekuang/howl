import Foundation
import Testing
@testable import HowlCore

@Suite("ScreenContextCache")
struct ScreenContextCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func stores_and_retrieves_by_key() {
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store(["MCP"], for: k, now: t0)
        #expect(c.value(for: k, now: t0) == ["MCP"])
    }

    @Test func miss_returns_nil() {
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        #expect(c.value(for: k, now: t0) == nil)
    }

    @Test func same_text_produces_same_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        #expect(a == b)
    }

    @Test func changed_text_produces_different_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.a", windowTitle: "Doc", text: "goodbye")
        #expect(a != b)
    }

    @Test func changed_bundle_id_produces_different_key() {
        let c = ScreenContextCache()
        let a = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        let b = c.key(bundleID: "com.b", windowTitle: "Doc", text: "hello")
        #expect(a != b)
    }

    @Test func entry_expires_after_ttl() {
        let c = ScreenContextCache(limit: 32, ttl: 600)
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store(["MCP"], for: k, now: t0)
        #expect(c.value(for: k, now: t0.addingTimeInterval(599)) == ["MCP"])
        #expect(c.value(for: k, now: t0.addingTimeInterval(601)) == nil)
    }

    @Test func evicts_least_recently_used_past_limit() {
        let c = ScreenContextCache(limit: 2, ttl: 600)
        let k1 = c.key(bundleID: "com.a", windowTitle: "1", text: "one")
        let k2 = c.key(bundleID: "com.a", windowTitle: "2", text: "two")
        let k3 = c.key(bundleID: "com.a", windowTitle: "3", text: "three")
        c.store(["A"], for: k1, now: t0)
        c.store(["B"], for: k2, now: t0)
        _ = c.value(for: k1, now: t0)          // k1 becomes most-recent
        c.store(["C"], for: k3, now: t0)       // evicts k2
        #expect(c.value(for: k1, now: t0) == ["A"])
        #expect(c.value(for: k2, now: t0) == nil)
        #expect(c.value(for: k3, now: t0) == ["C"])
    }

    @Test func empty_keyword_list_is_cached_as_a_real_result() {
        // A window that legitimately yields no keywords must not be
        // re-extracted on every focus.
        let c = ScreenContextCache()
        let k = c.key(bundleID: "com.a", windowTitle: "Doc", text: "hello")
        c.store([], for: k, now: t0)
        #expect(c.value(for: k, now: t0) == [])
    }
}
