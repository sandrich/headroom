import Foundation
import SQLite3
import Testing
@testable import Headroom

@Test func openCodeTurnsAreBucketedPerHourAndModel() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID()).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    let hour: Int64 = 500_000 * 3_600_000
    let turn = #"{"model":{"id":"glm-5.3"},"tokens":{"input":10,"output":5,"reasoning":2,"cache":{"read":100,"write":1}}}"#
    let sql = """
        CREATE TABLE session_message (id text PRIMARY KEY, session_id text, type text, seq integer,
                                      time_created integer, time_updated integer, data text);
        INSERT INTO session_message VALUES ('a', 's', 'assistant', 1, \(hour), \(hour + 9), '\(turn)');
        INSERT INTO session_message VALUES ('b', 's', 'assistant', 2, \(hour + 60_000), \(hour + 61_000), '\(turn)');
        INSERT INTO session_message VALUES ('c', 's', 'user', 3, \(hour), \(hour), '{"tokens":{"input":999}}');
        INSERT INTO session_message VALUES ('d', 's', 'assistant', 4, \(hour), \(hour), '{"model":{"id":"glm-5.3"}}');
        INSERT INTO session_message VALUES ('e', 's', 'assistant', 5, \(hour - 3_600_000), \(hour), '\(turn)');
        INSERT INTO session_message VALUES ('f', 's', 'assistant', 6, \(hour), \(hour), '{"model":{"id":"glm-5.3"},"content":"'
            || replace(zeroblob(8000000), zeroblob(1), 'x') || '","tokens":{"input":1,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let r = try #require(Ledger.queryOpenCode(path, since: hour))
    let hours = Ledger.bucket(r.turns)
    #expect(hours.count == 1)
    let a = try #require(hours[500_000]?["glm-5.3"])
    // Row f holds an 8 MB message: only its head and tail are read.
    #expect(a.input == 21 && a.output == 14 && a.cacheRead == 200 && a.cacheWrite5m == 2 && a.calls == 3)
    #expect(r.updated == hour + 61_000)
    #expect(Ledger.queryOpenCode(path, since: hour, updatedAfter: hour + 61_000)?.turns.map(\.key) == ["b"])
    #expect(Ledger.queryOpenCode("/nonexistent/opencode.db", since: 0) == nil)
}

/// A row holds the whole message (hundreds of MB for long sessions), so only its head and tail are parsed.
@Test func openCodeRowsAreParsedFromHeadAndTail() {
    let head = #"{"time":{"created":1},"agent":"build","model":{"id":"glm-5.3","providerID":"zai"},"content":[{"type":"text","text":"{"#
    let tail = #""model":{"id":"wrong"}"}],"finish":"stop","cost":0,"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}}}"#
    #expect(Ledger.jsonObject(after: "\"model\":", in: head)?["id"] as? String == "glm-5.3")
    let tokens = Ledger.jsonObject(after: "\"tokens\":", in: tail, backwards: true)
    #expect(tokens?["reasoning"] as? Int == 3 && (tokens?["cache"] as? [String: Any])?["write"] as? Int == 5)
    #expect(Ledger.jsonObject(after: "\"tokens\":", in: head) == nil)
    #expect(Ledger.jsonObject(after: "\"cost\":", in: tail) == nil)
}
