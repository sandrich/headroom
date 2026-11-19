import Foundation
import Testing
@testable import Headroom

struct NetworkTests {
    @Test(arguments: [
        (0.0, "0 KB/s"), (20.0, "0 KB/s"), (512.0, "0.5 KB/s"), (8_602.0, "8.4 KB/s"), (10_199.0, "10 KB/s"),
        (348_160.0, "340 KB/s"), (1_023_000.0, "999 KB/s"), (1_023_600.0, "1.0 MB/s"), (1_258_291.0, "1.2 MB/s"),
        (125_829_120.0, "120 MB/s"), (2_684_354_560.0, "2.5 GB/s"), (-5.0, "0 KB/s"),
    ])
    func rate(_ bps: Double, _ expected: String) {
        #expect(Fmt.rate(bps) == expected)
    }

    @Test func bytes() {
        #expect(Fmt.bytes(1_610_612_736) == "1.5 GB")
        #expect(Fmt.bytes(999.6 * 1_099_511_627_776) == "1000 TB")
        // Same unit as the memory card.
        #expect(Fmt.bytes(36 * 1_073_741_824) == "36 GB")
        #expect(Fmt.gb(36 * 1_073_741_824) == "36.0 GB")
    }

    @Test func parsesNettop() {
        let csv = """
        ,bytes_in,bytes_out,
        syslogd.577,0,30084,
        apsd.584,22108999,3656240,
        com.apple.WebKit.Networking.1234,100,50,
        odd,name.99,7,3,
        garbage line
        noPid,1,2,
        Safari.abc,1,2,
        """
        let r = ConsumerSampler.parseNettop(csv)
        #expect(r == [577: 30084, 584: 22108999 + 3656240, 1234: 150, 99: 10])
    }

    @Test func parsesNettopWithoutTrailingComma() {
        #expect(ConsumerSampler.parseNettop("Mail.42,10,5\n") == [42: 15])
    }

    @Test func deltaSumsInterfaces() {
        let prev = ["en0": NetCounter(rx: 1_000, tx: 500), "en1": NetCounter(rx: 10, tx: 10)]
        let cur = ["en0": NetCounter(rx: 3_000, tx: 600), "en1": NetCounter(rx: 20, tx: 15), "en5": NetCounter(rx: 9_999, tx: 9_999)]
        // en5 has no earlier reading, so it adds nothing yet.
        #expect(SystemSampler.netDelta(from: prev, to: cur) == NetCounter(rx: 2_010, tx: 105))
    }

    @Test func deltaIgnoresCounterReset() {
        let prev = ["en0": NetCounter(rx: 5_000_000, tx: 4_000)]
        let cur = ["en0": NetCounter(rx: 1_000, tx: 4_100)]
        #expect(SystemSampler.netDelta(from: prev, to: cur) == NetCounter(rx: 0, tx: 100))
    }
}
