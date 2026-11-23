import Foundation
import Testing
@testable import Headroom

struct SpendTests {
    private func json(_ s: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    @Test func claudeSpendInMinorUnits() throws {
        let s = try #require(ClaudeLimitsClient.parseSpend(try json("""
            {"spend": {"enabled": true, "used": {"amount_minor": 12468, "exponent": 2, "currency": "USD"},
                       "limit": {"amount_minor": 20000, "exponent": 2, "currency": "USD"}}}
            """)))
        #expect(s.name == "Usage credits")
        #expect(abs(s.percent - 62.34) < 0.001)
        #expect(s.note == "$124.68 of $200.00")
        #expect(s.resetsAt == nil)
    }

    @Test func claudeSpendCapAndPlainNumbers() throws {
        let s = try #require(ClaudeLimitsClient.parseSpend(try json("""
            {"spend": {"enabled": true, "used": 30, "cap": {"money": {"amount_minor": 5000, "currency": "EUR"}}}}
            """)))
        #expect(s.percent == 60)
        #expect(s.note == "30.00 EUR of 50.00 EUR")
    }

    @Test func claudeOlderExtraUsageShape() throws {
        let s = try #require(ClaudeLimitsClient.parseSpend(try json("""
            {"extra_usage": {"is_enabled": false, "monthly_limit": 20000, "used_credits": 25000, "decimal_places": 2, "currency": "USD "}}
            """)))
        #expect(s.percent == 100) // clamped
        #expect(s.note == "$250.00 of $200.00, turned off")
    }

    @Test func claudeFallsBackToServerPercent() throws {
        let s = try #require(ClaudeLimitsClient.parseSpend(try json("""
            {"extra_usage": {"is_enabled": true, "monthly_limit": 10000, "utilization": 12.5}}
            """)))
        #expect(s.percent == 12.5)
        #expect(s.note == "$100.00 limit")
    }

    @Test(arguments: [
        #"{}"#,
        #"{"spend": null}"#,
        #"{"extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null}}"#,
        #"{"extra_usage": {"is_enabled": true, "monthly_limit": 0, "used_credits": 0}}"#,
        #"{"spend": {"enabled": true, "balance": {"amount_minor": 500}}}"#,
    ])
    func claudeNoSpendLimit(_ body: String) throws {
        #expect(ClaudeLimitsClient.parseSpend(try json(body)) == nil)
    }
}
