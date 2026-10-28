import Foundation
import Testing
@testable import Headroom

struct FormattingTests {
    @Test(arguments: [
        (0, "0"), (999, "999"), (1_500, "1.5K"), (2_340_000, "2.3M"), (10_660_000_000, "10.66B"),
    ])
    func tokens(_ n: Int, _ expected: String) {
        #expect(Fmt.tokens(n) == expected)
    }

    @Test func usd() {
        #expect(Fmt.usd(nil) == "n/a")
        #expect(Fmt.usd(7.538) == "$7.54")
        #expect(Fmt.usd(715.4) == "$715")
        #expect(Fmt.usd(4_900) == "$4.9k")
    }

    @Test func percentAndGigabytes() {
        #expect(Fmt.pct(nil) == "--")
        #expect(Fmt.pct(26.6) == "27%")
        #expect(Fmt.gb(36 * 1_073_741_824) == "36.0 GB")
    }

    @Test func until() {
        #expect(Fmt.until(nil) == "")
        #expect(Fmt.until(Date().addingTimeInterval(-10)) == "now")
        #expect(Fmt.until(Date().addingTimeInterval(20)) == "1m")
        #expect(Fmt.until(Date().addingTimeInterval(2 * 3600 + 50 * 60 + 30)) == "2h 50m")
        #expect(Fmt.until(Date().addingTimeInterval(2 * 86400 + 18 * 3600 + 30)) == "2d 18h")
    }

    @Test func ago() {
        #expect(Fmt.ago(nil) == "never")
        #expect(Fmt.ago(Date()) == "just now")
        #expect(Fmt.ago(Date().addingTimeInterval(-7)) == "7s ago")
        #expect(Fmt.ago(Date().addingTimeInterval(-125)) == "2m ago")
        #expect(Fmt.ago(Date().addingTimeInterval(-7300)) == "2h ago")
    }

    @Test func duration() {
        #expect(Fmt.duration(minutes: 66) == "1:06")
        #expect(Fmt.duration(minutes: 5) == "0:05")
    }
}

struct ISOTests {
    @Test func parsesCommonForms() throws {
        let expected = try #require(ISO.parse("2026-10-13T08:00:00Z"))
        #expect(ISO.parse("2026-10-13T08:00:00.000Z") == expected)
        #expect(ISO.parse("2026-10-13T10:00:00+02:00") == expected)
    }

    @Test(arguments: ["2026-10-13T08:00:00Z", "2026-10-13T08:00:00.5Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z",
                      "2026-01-01T00:00:00.123456789Z", "2100-03-01T12:30:45Z"])
    func fastPathMatchesTheFormatter(_ s: String) throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        let expected = try #require(f.date(from: s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)))
        let fast = try #require(ISO.fast(s))
        #expect(abs(fast.timeIntervalSince(expected)) < 0.001)
    }

    @Test(arguments: ["2026-10-13T10:00:00+02:00", "2026-10-13T08:00:00", "2026-13-13T08:00:00Z", "2026-10-13T08:00:00.12xZ", "garbage"])
    func fastPathRejectsOtherForms(_ s: String) {
        #expect(ISO.fast(s) == nil)
    }

    @Test func parsesLongFractions() throws {
        // Grok writes nanosecond fractions.
        let d = try #require(ISO.parse("2026-10-13T08:00:00.123456789Z"))
        let whole = try #require(ISO.parse("2026-10-13T08:00:00Z"))
        #expect(abs(d.timeIntervalSince(whole) - 0.123) < 0.001)
    }

    @Test(arguments: [nil, "", "not a date", "2026-13-45"])
    func rejectsGarbage(_ s: String?) {
        #expect(ISO.parse(s) == nil)
    }
}
