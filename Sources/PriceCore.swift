import Foundation

enum Currency: String, CaseIterable, Sendable {
    case eur = "EUR"
    case usd = "USD"

    var symbol: String { self == .eur ? "€" : "$" }
    var tickerKey: String { self == .eur ? "XXBTZEUR" : "XXBTZUSD" }
}

struct PriceSnapshot: Codable, Equatable, Sendable {
    let eur: Decimal
    let usd: Decimal
    // Empfangszeit, kein Zeitstempel des letzten Handels.
    let receivedAt: Date

    subscript(currency: Currency) -> Decimal { currency == .eur ? eur : usd }

    var isValid: Bool {
        [eur, usd].allSatisfy { !$0.isNaN && $0 > 0 && NSDecimalNumber(decimal: $0).doubleValue.isFinite }
            && receivedAt.timeIntervalSince1970.isFinite
    }
}

enum PriceError: Error, LocalizedError, Equatable {
    case invalidResponse
    case http(Int)
    case oversizedResponse
    case api([String])
    case malformedTicker

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Ungültige Serverantwort"
        case .http(let code): return "HTTP \(code)"
        case .oversizedResponse: return "Serverantwort zu groß"
        case .api(let errors): return "Kraken: " + errors.joined(separator: ", ")
        case .malformedTicker: return "Ungültige Kraken-Kursdaten"
        }
    }
}

enum KrakenTicker {
    static let endpoint = URL(string: "https://api.kraken.com/0/public/Ticker?pair=XBTEUR,XBTUSD")!

    private struct Envelope: Decodable {
        let error: [String]
        // Bei API-Fehlern kann result fehlen.
        let result: [String: Ticker]?

        enum CodingKeys: String, CodingKey { case error, result }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decode([String].self, forKey: .error)
            if error.isEmpty {
                result = try container.decode([String: Ticker].self, forKey: .result)
            } else {
                result = nil
            }
        }
    }

    private struct Ticker: Decodable { let c: [String] }

    static func decode(_ data: Data, receivedAt: Date) throws -> PriceSnapshot {
        guard data.count <= 1_048_576 else { throw PriceError.oversizedResponse }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw PriceError.malformedTicker }
        guard envelope.error.isEmpty else { throw PriceError.api(envelope.error) }
        func price(_ currency: Currency) throws -> Decimal {
            guard let value = envelope.result?[currency.tickerKey]?.c.first,
                  value.count <= 128,
                  value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                  !decimal.isNaN, decimal > 0,
                  NSDecimalNumber(decimal: decimal).doubleValue.isFinite else {
                throw PriceError.malformedTicker
            }
            return decimal
        }
        let snapshot = try PriceSnapshot(eur: price(.eur), usd: price(.usd), receivedAt: receivedAt)
        guard snapshot.isValid else { throw PriceError.malformedTicker }
        return snapshot
    }

    static func decodeResponse(data: Data, response: URLResponse, receivedAt: Date) throws -> PriceSnapshot {
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw PriceError.http(http.statusCode) }
        return try decode(data, receivedAt: receivedAt)
    }

    static func fetch(using session: URLSession) async throws -> PriceSnapshot {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return try decodeResponse(data: data, response: response, receivedAt: Date())
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

enum PriceFormatting {
    static func title(snapshot: PriceSnapshot?, currency: Currency, stale: Bool) -> String {
        guard let snapshot else { return "₿ \(currency.symbol)— ⚠" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currency == .eur ? "de_DE" : "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        let value = formatter.string(from: NSDecimalNumber(decimal: snapshot[currency])) ?? "—"
        return "₿ \(currency.symbol)\(value)" + (stale ? " ⚠" : "")
    }
}

protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

final class Preferences {
    private let store: any PreferenceStore
    private let currencyKey = "selectedCurrency"
    private let cacheKey = "lastGoodSnapshot.v1"

    init(store: any PreferenceStore = UserDefaults.standard) { self.store = store }

    var currency: Currency {
        get { store.string(forKey: currencyKey).flatMap(Currency.init(rawValue:)) ?? .eur }
        set { store.set(newValue.rawValue, forKey: currencyKey) }
    }

    func loadSnapshot(now: Date = Date()) -> PriceSnapshot? {
        guard let data = store.data(forKey: cacheKey),
              let snapshot = try? JSONDecoder().decode(PriceSnapshot.self, from: data),
              snapshot.isValid, snapshot.receivedAt <= now else { return nil }
        return snapshot
    }

    func save(snapshot: PriceSnapshot) {
        guard snapshot.isValid, let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: cacheKey)
    }
}

struct PriceState {
    static let staleAfter: TimeInterval = 65
    private(set) var snapshot: PriceSnapshot?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var hasLiveSuccess = false

    init(cached: PriceSnapshot? = nil) { snapshot = cached }

    mutating func beginRefresh() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    mutating func succeed(_ snapshot: PriceSnapshot) {
        self.snapshot = snapshot
        lastError = nil
        hasLiveSuccess = true
        isRefreshing = false
    }

    mutating func fail(_ message: String) {
        lastError = message
        isRefreshing = false
    }

    func isStale(now: Date) -> Bool {
        guard let snapshot else { return true }
        return !hasLiveSuccess || lastError != nil || now.timeIntervalSince(snapshot.receivedAt) >= Self.staleAfter
            || now < snapshot.receivedAt
    }

    func tooltip(now: Date) -> String {
        var lines = ["Bitcoin · Kraken · letzter Handel"]
        if let snapshot {
            let date = DateFormatter()
            date.locale = Locale(identifier: "de_DE")
            date.dateStyle = .medium
            date.timeStyle = .medium
            lines.append("Zuletzt empfangen: \(date.string(from: snapshot.receivedAt)) (lokale Zeit)")
            lines.append(isStale(now: now) ? "⚠ Veraltet – letzter guter Kurs" : "Aktuell · Abruf alle 30 Sekunden")
        } else {
            lines.append(isRefreshing ? "Kurse werden geladen …" : "Noch kein Kurs verfügbar")
        }
        if let lastError { lines.append("Abruf fehlgeschlagen: \(lastError)") }
        return lines.joined(separator: "\n")
    }
}
