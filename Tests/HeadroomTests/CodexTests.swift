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
}
