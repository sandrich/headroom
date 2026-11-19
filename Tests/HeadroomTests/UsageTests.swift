import Foundation
import Testing
@testable import Headroom

struct UsageTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus"), ("claude-fable-5-1", "Fable"), ("claude-sonnet-5", "Sonnet"),
        ("claude-haiku-4-5-20251001", "Haiku"), ("grok-4.6-build", "Grok"), ("gpt-6-luna", "GPT"), ("some-other-model", "some-other-model"),
    ])
    func modelFamilies(_ model: String, _ family: String) {
        #expect(modelFamily(model) == family)
    }

    @Test func aggregateMath() {
        var a = Agg(input: 10, output: 5, cacheWrite5m: 2, cacheWrite1h: 1, cacheRead: 100, calls: 1)
        #expect(a.total == 118)

        let grown = Agg(input: 12, output: 9, cacheWrite5m: 2, cacheWrite1h: 1, cacheRead: 90, calls: 3).growth(from: a)
        #expect(grown.input == 2 && grown.output == 4 && grown.cacheRead == 0 && grown.calls == 0)

        let maxed = a.maxed(with: Agg(input: 3, output: 50))
        #expect(maxed.input == 10 && maxed.output == 50)

        a.add(Agg(input: 1, costTicks: 7))
        a.add(Agg(input: 1, costTicks: 3))
        #expect(a.input == 12 && a.costTicks == 10)
    }

    @Test func providerCostTicks() {
        // Grok reports exact cost in 1e-10 USD ticks; no pricing table needed.
        #expect(Pricing.shared.cost(model: "grok-4.6-build", Agg(costTicks: 25_000_000_000)) == 2.5)
    }

    @Test func combineSummaries() throws {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var claude = UsageSummary()
        claude.today = Totals(tokens: 100, cost: 1)
        claude.window = Totals(tokens: 40, cost: 0.4)
        claude.models = [ModelRow(model: "claude-opus-5-5", tokens: 100, cost: 1)]
        claude.bars = [DayBar(day: day, family: "Opus", tokens: 100, cost: 1)]
        var grok = UsageSummary()
        grok.today = Totals(tokens: 300, cost: 0.5)
        grok.models = [ModelRow(model: "grok-4.6-build", tokens: 300, cost: 0.5)]
        grok.bars = [DayBar(day: day, family: "Grok", tokens: 300, cost: 0.5)]

        let both = try #require(UsageSummary.combine(claude, grok))
        #expect(both.today.tokens == 400 && both.today.cost == 1.5)
        #expect(both.window?.tokens == 40)
        #expect(both.models.map(\.model) == ["grok-4.6-build", "claude-opus-5-5"])
        #expect(both.bars.map(\.family) == ["Grok", "Opus"])

        #expect(UsageSummary.combine(nil, grok)?.today.tokens == 300)
        #expect(UsageSummary.combine(nil, nil) == nil)
    }
}

struct StoreTests {
    @Test func historyIsCapped() {
        let store = Store()
        for i in 0..<(Store.historyLength + 20) {
            store.record(cpu: CPUSample(total: Double(i), user: 0, system: 0, cores: []), gpu: nil, memory: nil, network: nil)
        }
        #expect(store.cpuHistory.count == Store.historyLength)
        #expect(store.cpuHistory.last?.v == Double(Store.historyLength + 19))
        #expect(store.gpuHistory.isEmpty)
    }

    @Test func severity() {
        #expect(Palette.severity(nil, base: .blue) == .blue)
        #expect(Palette.severity(50, base: .blue) == .blue)
        #expect(Palette.severity(80, base: .blue) == .systemOrange)
        #expect(Palette.severity(95, base: .blue) == .systemRed)
    }
}
