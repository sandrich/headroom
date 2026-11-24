import Foundation
import Testing
@testable import Headroom

struct CodexTests {
    @Test func parsesUsageWindows() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data("""
            {"plan_type": "plus", "rate_limit": {
              "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1795420109},
              "secondary_window": {"used_percent": 7.5, "limit_window_seconds": 604800, "reset_at": 1795900000}}}
            """.utf8)) as? [String: Any])
        let l = CodexClient.parse(json)
        #expect(l.plan == "Plus")
        #expect(l.all.map(\.name) == ["Session (5h)", "Weekly"])
        #expect(l.all.map(\.percent) == [42, 7.5])
        #expect(l.all[0].resetsAt == Date(timeIntervalSince1970: 1795420109))
        #expect(l.all[1].window == 604800)
    }

    @Test(arguments: [(2592000.0, "Monthly"), (86400 * 3, "3 days"), (7200, "2h"), (0, "Limit")])
    func windowNames(_ seconds: Double, _ name: String) {
        #expect(CodexClient.windowName(seconds) == name)
    }

    @Test func rolloutRecordsTakeTheTurnModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func record(_ id: String, _ ts: String) -> String {
            #"{"timestamp":"\#(ts)","type":"token_usage_record","payload":{"response_id":"\#(id)","usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":20,"total_tokens":1050}}}"#
        }
        try [
            #"{"timestamp":"2026-10-24T07:48:26.760Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}"#,
            #"{"timestamp":"2026-10-24T07:48:27.000Z","type":"response_item","payload":{"type":"message","content":"token_usage_record"}}"#,
            record("resp_a", "2026-10-24T07:48:27.871Z"),
            #"{"timestamp":"2026-10-24T08:10:00.000Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}"#,
            record("resp_b", "2026-10-24T08:10:01.000Z"),
        ].map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)

        var model = "gpt"
        var turns: [Ledger.CodexTurn] = []
        var offset = Ledger.parseCodexRollout(url.path, model: &model, into: &turns)
        #expect(turns.map(\.key) == ["resp_a", "resp_b"])
        #expect(turns.map(\.model) == ["gpt-6-luna", "gpt-6-sol"])
        let a = turns[0].agg
        #expect(a.input == 200 && a.cacheRead == 800 && a.output == 50 && a.calls == 1)
        #expect(turns[1].hour - turns[0].hour == 1)

        // Rollouts are appended to: only the new bytes are read, and the model carries over.
        let more = (record("resp_c", "2026-10-24T08:20:00.000Z") + "\n").data(using: .utf8)!
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile(); h.write(more); try h.close()
        let size = try #require((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? UInt64)
        offset = Ledger.parseCodexRollout(url.path, from: offset, model: &model, into: &turns)
        #expect(turns.map(\.key) == ["resp_a", "resp_b", "resp_c"] && turns[2].model == "gpt-6-sol" && offset == size)
    }

    @Test func betweenFullScansOnlyHotAndTodaysRolloutsAreRead() throws {
        let fm = FileManager.default
        // Canonical (/private/var/...), so the paths from the directory walk and from the listing agree as they do under ~.
        let tmp = try #require(try fm.temporaryDirectory.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let root = URL(fileURLWithPath: tmp).appendingPathComponent("codex-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/MM/dd"
        let today = root.appendingPathComponent("sessions/\(fmt.string(from: Date()))")
        let old = root.appendingPathComponent("sessions/2020/01/01")
        for dir in [today, old] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func record(_ id: String) -> Data {
            Data((#"{"timestamp":"2026-10-24T07:48:27.871Z","type":"token_usage_record","payload":{"response_id":"\#(id)","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}"# + "\n").utf8)
        }
        func keys(_ files: [String: Ledger.CodexFile]) -> [String] { files.values.flatMap(\.turns).map(\.key).sorted() }
        let known = today.appendingPathComponent("known.jsonl")
        try record("a").write(to: known)

        var files: [String: Ledger.CodexFile] = [:]
        var hot = Set<String>()
        #expect(Ledger.scanCodex(root: root, full: true, files: &files, hot: &hot).changed == 1)
        #expect(hot == [known.path] && keys(files) == ["a"])

        let h = try FileHandle(forWritingTo: known)
        h.seekToEndOfFile(); h.write(record("b")); try h.close()
        try record("c").write(to: today.appendingPathComponent("new.jsonl"))
        try record("d").write(to: old.appendingPathComponent("unseen.jsonl")) // only a full walk finds this one

        let r = Ledger.scanCodex(root: root, full: false, files: &files, hot: &hot)
        #expect(r.changed == 2 && keys(files) == ["a", "b", "c"] && hot.count == 2)
        #expect(r.newest.timeIntervalSinceNow > -60)
        #expect(Ledger.scanCodex(root: root, full: false, files: &files, hot: &hot).changed == 0)
        #expect(Ledger.scanCodex(root: root, full: true, files: &files, hot: &hot).changed == 1)
        #expect(keys(files) == ["a", "b", "c", "d"])
    }

    private func json(_ s: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    @Test func spendControlAndCredits() throws {
        let l = CodexClient.parse(try json("""
            {"plan_type": "business", "rate_limit": null,
             "spend_control": {"reached": false, "individual_limit": {"remaining_percent": 35, "reset_at": 1795900000}},
             "credits": {"has_credits": true, "unlimited": false, "balance": "120"}}
            """))
        let s = try #require(l.spend)
        #expect(s.name == "Spend limit")
        #expect(s.percent == 65)
        #expect(s.resetsAt == Date(timeIntervalSince1970: 1795900000))
        #expect(l.credits == "120 credits left")
        #expect(l.all.isEmpty) // the menu bar gauges stay on the rate limits
    }

    @Test func reachedSpendLimitAndNumericBalance() throws {
        let l = CodexClient.parse(try json("""
            {"plan_type": "business",
             "spend_control": {"reached": true, "individual_limit": {"remaining_percent": 3}},
             "credits": {"has_credits": true, "unlimited": false, "balance": 7.5}}
            """))
        #expect(l.spend?.percent == 100)
        #expect(l.credits == "7.50 credits left")
    }

    @Test func withoutSpendControlOrCredits() throws {
        let l = CodexClient.parse(try json("""
            {"plan_type": "plus", "spend_control": {"reached": false, "individual_limit": null},
             "credits": {"has_credits": true, "unlimited": true, "balance": "0"}}
            """))
        #expect(l.spend == nil && l.credits == nil)
    }
}
