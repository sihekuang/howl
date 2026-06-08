import Foundation
import Testing
@testable import HowlCore

@Suite("HIDBinding")
struct HIDBindingTests {
    @Test func roundTripCodable() throws {
        let b = HIDBinding(vendorID: 0x046D, productID: 0xC52B, usagePage: 0x09, usage: 0x01)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(HIDBinding.self, from: data)
        #expect(back == b)
    }

    @Test func equatableDistinguishesElements() {
        let base = HIDBinding(vendorID: 1, productID: 2, usagePage: 0x09, usage: 0x01)
        // Same device, different element → not equal.
        let otherElement = HIDBinding(vendorID: 1, productID: 2, usagePage: 0x09, usage: 0x02)
        #expect(base != otherElement)
    }
}
