import Foundation

final class MemoryStore: PreferenceStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

struct TestFailure: Error, CustomStringConvertible { let description: String }

@main
struct PriceCoreTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    static func expectError(_ expected: PriceError, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as PriceError {
            try check(error == expected, "Expected \(expected), got \(error)")
            return
        }
        throw TestFailure(description: "Expected \(expected), but operation succeeded")
    }

    static func fixture(eur: String = "67234.50000", usd: String = "73123.49000") -> Data {
        Data("""
        {"error":[],"result":{"XXBTZEUR":{"c":["\(eur)","0.1"],"a":["99999"]},
        "XXBTZUSD":{"c":["\(usd)","0.2"]}}}
        """.utf8)
    }

    static func main() async {
        do {
            try await run()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = try KrakenTicker.decode(fixture(), receivedAt: now)
        try check(snapshot.eur == Decimal(string: "67234.5")!, "EUR must use last trade c[0]")
        try check(snapshot.usd == Decimal(string: "73123.49")!, "USD must use last trade c[0]")
        try check(snapshot.receivedAt == now, "Use receipt timestamp")
        try check(snapshot[.eur] == snapshot.eur && snapshot[.usd] == snapshot.usd, "Currency mapping")
        print("PASS ticker keys, both currencies, c[0], receipt timestamp")

        let badPayloads = [
            "not json", "{}", "{\"result\":{}}", "{\"error\":[],\"result\":{}}",
            "{\"error\":[],\"result\":{\"XXBTZEUR\":{\"c\":[\"1\"]}}}",
            "{\"error\":[],\"result\":{\"XBTEUR\":{\"c\":[\"1\"]},\"XBTUSD\":{\"c\":[\"2\"]}}}",
            "{\"error\":[],\"result\":{\"XXBTZEUR\":{\"c\":[]},\"XXBTZUSD\":{\"c\":[\"2\"]}}}",
            "{\"error\":[],\"result\":{\"XXBTZEUR\":{\"c\":[1]},\"XXBTZUSD\":{\"c\":[\"2\"]}}}"
        ]
        for body in badPayloads {
            try expectError(.malformedTicker) { _ = try KrakenTicker.decode(Data(body.utf8), receivedAt: now) }
        }
        for bad in ["0", "-1", "NaN", "Infinity", "", "1,23", "1.2junk", "1e3", " 12", ".5", String(repeating: "9", count: 150)] {
            try expectError(.malformedTicker) { _ = try KrakenTicker.decode(fixture(eur: bad), receivedAt: now) }
            try expectError(.malformedTicker) { _ = try KrakenTicker.decode(fixture(usd: bad), receivedAt: now) }
        }
        try expectError(.api(["EGeneral:Busy"])) {
            _ = try KrakenTicker.decode(Data(#"{"error":["EGeneral:Busy"],"result":null}"#.utf8), receivedAt: now)
        }
        try expectError(.oversizedResponse) {
            _ = try KrakenTicker.decode(Data(repeating: 32, count: 1_048_577), receivedAt: now)
        }
        let ok = HTTPURLResponse(url: KrakenTicker.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let rejected = HTTPURLResponse(url: KrakenTicker.endpoint, statusCode: 503, httpVersion: nil, headerFields: nil)!
        let decoded = try KrakenTicker.decodeResponse(data: fixture(), response: ok, receivedAt: now)
        try check(decoded == snapshot, "HTTP 200 decoding")
        try expectError(.http(503)) { _ = try KrakenTicker.decodeResponse(data: fixture(), response: rejected, receivedAt: now) }
        let nonHTTP = URLResponse(url: KrakenTicker.endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        try expectError(.invalidResponse) { _ = try KrakenTicker.decodeResponse(data: fixture(), response: nonHTTP, receivedAt: now) }
        print("PASS malformed/missing/partial tickers, invalid prices, API/HTTP errors, response limit")

        try check(PriceFormatting.title(snapshot: snapshot, currency: .eur, stale: false) == "₿ €67.235", "EUR grouping and half-up rounding")
        try check(PriceFormatting.title(snapshot: snapshot, currency: .usd, stale: false) == "₿ $73,123", "USD grouping and rounding")
        try check(PriceFormatting.title(snapshot: snapshot, currency: .usd, stale: true) == "₿ $73,123 ⚠", "Visible stale marker")
        try check(PriceFormatting.title(snapshot: nil, currency: .eur, stale: true) == "₿ €— ⚠", "Missing price must never be zero")
        print("PASS whole-unit formatting, symbols, grouping, stale and missing-price display")

        let store = MemoryStore()
        let preferences = Preferences(store: store)
        try check(preferences.currency == .eur, "EUR is the default")
        preferences.currency = .usd
        try check(Preferences(store: store).currency == .usd, "Currency persists across instances")
        store.values["selectedCurrency"] = "JPY"
        try check(preferences.currency == .eur, "Invalid preference recovers to EUR")
        try check(preferences.loadSnapshot(now: now) == nil, "No cache initially")
        preferences.save(snapshot: snapshot)
        try check(Preferences(store: store).loadSnapshot(now: now) == snapshot, "Last good cache round trip")
        try check(preferences.loadSnapshot(now: now.addingTimeInterval(-1)) == nil, "Reject future cache")
        preferences.save(snapshot: PriceSnapshot(eur: 0, usd: 10, receivedAt: now))
        try check(preferences.loadSnapshot(now: now) == snapshot, "Invalid cache cannot overwrite last good")
        store.values["lastGoodSnapshot.v1"] = Data("broken".utf8)
        try check(preferences.loadSnapshot(now: now) == nil, "Corrupt cache recovers")
        print("PASS default/persisted preferences, valid/corrupt/future cache, last-good preservation")

        var state = PriceState()
        try check(state.isStale(now: now), "No price is stale")
        try check(state.beginRefresh(), "First request starts")
        try check(!state.beginRefresh(), "Overlapping request is blocked")
        state.fail("offline")
        try check(state.snapshot == nil, "First failure cannot fabricate a price")
        try check(state.beginRefresh(), "Failure releases request gate")
        state.succeed(snapshot)
        try check(!state.isStale(now: now), "Fresh success")
        try check(!state.isStale(now: now.addingTimeInterval(64)), "Fresh before threshold")
        try check(state.isStale(now: now.addingTimeInterval(65)), "Stale at threshold")
        try check(state.isStale(now: now.addingTimeInterval(-1)), "Clock rollback is stale")
        try check(state.beginRefresh(), "Success releases request gate")
        try check(!state.isStale(now: now), "In-flight refresh retains freshness")
        state.fail("timeout")
        try check(state.snapshot == snapshot && state.isStale(now: now), "Failure preserves last good and marks stale immediately")
        let tooltip = state.tooltip(now: now)
        try check(tooltip.contains("Kraken") && tooltip.contains("Zuletzt empfangen:") && tooltip.contains("timeout"),
                  "Tooltip includes source, time and error")
        try check(state.beginRefresh(), "Retry starts")
        state.succeed(snapshot)
        try check(!state.isStale(now: now) && state.lastError == nil, "Successful retry clears stale error")
        try check(PriceState(cached: snapshot).isStale(now: now), "Restored cache stays stale until live validation")
        let session = KrakenTicker.makeSession()
        try check(session.configuration.timeoutIntervalForRequest == 12, "Request timeout")
        try check(session.configuration.timeoutIntervalForResource == 15, "Resource timeout")
        print("PASS overlap prevention, failures/recovery, stale timing, cache startup, tooltip, timeouts")

        if CommandLine.arguments.contains("--live") {
            let live = try await KrakenTicker.fetch(using: session)
            print("LIVE PASS \(KrakenTicker.endpoint.absoluteString)")
            print("LIVE EUR=\(live.eur) USD=\(live.usd) receivedAt=\(ISO8601DateFormatter().string(from: live.receivedAt))")
        }
        session.finishTasksAndInvalidate()
        print("ALL TESTS PASSED")
    }
}
