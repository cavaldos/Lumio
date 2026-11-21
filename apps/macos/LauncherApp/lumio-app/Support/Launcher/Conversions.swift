//
//  Conversions.swift
//  lumio-app
//
//  Unit and currency conversion in the search field, next to the calculator:
//
//    5 km to miles        72 f in c          1.5 gb in mb        90 min to hours
//    100 usd to gbp       $250 in eur        £40                 (→ your own currency)
//
//  Units are Foundation's own (`Measurement`), so the factors are Apple's. Currency uses the
//  European Central Bank's public daily reference rates (about 30 major currencies), fetched
//  at most twice a day and kept on disk, so a conversion never waits on the network and
//  works offline with the last rates. The request sends nothing about you or what you typed.
//

import Foundation

nonisolated enum Conversions {
    struct Result: Equatable, Sendable {
        /// "3.11 mi"
        let output: String
        /// "Length" / "ECB rate, 19 Nov"
        let detail: String
    }

    /// The conversion `text` asks for, or nil when it is not one.
    static func evaluate(_ text: String, rates: CurrencyRates.Snapshot? = CurrencyRates.shared.snapshot) -> Result? {
        guard let query = parse(text) else { return nil }
        if let to = query.to {
            // Same kind of unit on both sides (km → miles). Tried first, so "5 pounds to kg" is weight.
            // (Compared by our own kind label: Foundation's built-in units are private subclasses.)
            if let from = unit(query.from), let target = unit(to), from.kind == target.kind {
                let value = Measurement(value: query.amount, unit: from.unit).converted(to: target.unit).value
                return Result(output: number(value) + " " + target.symbol, detail: from.kind)
            }
            if let rates, let from = currency(query.from, rates), let target = currency(to, rates) {
                return money(query.amount, from: from, to: target, rates: rates)
            }
            return nil
        }
        // "£40", "100 usd": into the Mac's own currency.
        guard let rates, let from = currency(query.from, rates, strict: true),
              let home = Locale.current.currency?.identifier.uppercased(), home != from,
              rates.perEuro[home] != nil
        else { return nil }
        return money(query.amount, from: from, to: home, rates: rates)
    }

    // MARK: - Parsing

    private struct Query {
        let amount: Double
        let from: String
        let to: String?
    }

    private static let signs: [Character: String] = ["$": "usd", "€": "eur", "£": "gbp", "¥": "jpy", "₹": "inr"]

    /// "<amount> <unit> (to|in|as|->|=) <unit>", "<sign><amount> to <unit>", "<amount> <code>".
    private static func parse(_ text: String) -> Query? {
        var rest = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = rest.first else { return nil }
        var leadingSign: String?
        if let code = signs[first] {
            leadingSign = code
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // The number.
        var digits = ""
        var index = rest.startIndex
        while index < rest.endIndex, rest[index].isNumber || rest[index] == "." || rest[index] == ","
            || (digits.isEmpty && rest[index] == "-")
        {
            digits.append(rest[index])
            index = rest.index(after: index)
        }
        guard let amount = Double(digits.replacingOccurrences(of: ",", with: "")), amount.isFinite else { return nil }
        var tail = rest[index...].trimmingCharacters(in: .whitespaces)
        // Trailing sign: "20€ to gbp".
        if leadingSign == nil, let sign = tail.first, let code = signs[sign] {
            leadingSign = code
            tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        for connector in [" to ", " in ", " as ", " -> ", " = "] {
            let padded = " " + tail + " "
            guard let range = padded.range(of: connector) else { continue }
            let from = padded[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = padded[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty else { return nil }
            if let leadingSign { return from.isEmpty ? Query(amount: amount, from: leadingSign, to: to) : nil }
            return from.isEmpty ? nil : Query(amount: amount, from: from, to: to)
        }
        if let leadingSign { return tail.isEmpty ? Query(amount: amount, from: leadingSign, to: nil) : nil }
        return tail.isEmpty ? nil : Query(amount: amount, from: tail, to: nil)
    }

    // MARK: - Units

    private struct UnitEntry {
        let unit: Dimension
        let symbol: String
        let kind: String
    }

    private static func unit(_ name: String) -> UnitEntry? {
        let key = name.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: " ", with: "")
        if let hit = units[key] { return hit }
        // Plural: "miles" → "mile". Not for short symbols ("ms" is milliseconds, not metres).
        if key.count > 3, key.hasSuffix("s"), let hit = units[String(key.dropLast())] { return hit }
        return nil
    }

    // Read-only after first use; Dimension is an immutable class Foundation doesn't mark Sendable.
    nonisolated(unsafe) private static let units: [String: UnitEntry] = {
        var table: [String: UnitEntry] = [:]
        func add(_ unit: Dimension, _ symbol: String, _ kind: String, _ names: String...) {
            for name in names { table[name] = UnitEntry(unit: unit, symbol: symbol, kind: kind) }
        }
        add(UnitLength.millimeters, "mm", "Length", "mm", "millimeter", "millimetre")
        add(UnitLength.centimeters, "cm", "Length", "cm", "centimeter", "centimetre")
        add(UnitLength.meters, "m", "Length", "m", "meter", "metre")
        add(UnitLength.kilometers, "km", "Length", "km", "kilometer", "kilometre")
        add(UnitLength.inches, "in", "Length", "in", "inch", "inche", "\"")
        add(UnitLength.feet, "ft", "Length", "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "Length", "yd", "yard")
        add(UnitLength.miles, "mi", "Length", "mi", "mile")
        add(UnitLength.nauticalMiles, "nmi", "Length", "nmi", "nauticalmile")

        add(UnitMass.milligrams, "mg", "Weight", "mg", "milligram")
        add(UnitMass.grams, "g", "Weight", "g", "gram", "gramme")
        add(UnitMass.kilograms, "kg", "Weight", "kg", "kilo", "kilogram", "kilogramme")
        add(UnitMass.ounces, "oz", "Weight", "oz", "ounce")
        add(UnitMass.pounds, "lb", "Weight", "lb", "lbs", "pound")
        add(UnitMass.stones, "st", "Weight", "st", "stone")
        add(UnitMass.metricTons, "t", "Weight", "t", "tonne", "ton")

        add(UnitTemperature.celsius, "°C", "Temperature", "c", "celsius", "centigrade")
        add(UnitTemperature.fahrenheit, "°F", "Temperature", "f", "fahrenheit")
        add(UnitTemperature.kelvin, "K", "Temperature", "k", "kelvin")

        add(UnitVolume.milliliters, "ml", "Volume", "ml", "milliliter", "millilitre")
        add(UnitVolume.liters, "L", "Volume", "l", "liter", "litre")
        add(UnitVolume.teaspoons, "tsp", "Volume", "tsp", "teaspoon")
        add(UnitVolume.tablespoons, "tbsp", "Volume", "tbsp", "tablespoon")
        add(UnitVolume.cups, "cups", "Volume", "cup")
        add(UnitVolume.fluidOunces, "fl oz", "Volume", "floz", "fluidounce")
        add(UnitVolume.pints, "pt", "Volume", "pt", "pint")
        add(UnitVolume.quarts, "qt", "Volume", "qt", "quart")
        add(UnitVolume.gallons, "gal", "Volume", "gal", "gallon")

        add(UnitSpeed.kilometersPerHour, "km/h", "Speed", "kmh", "kph", "km/h")
        add(UnitSpeed.milesPerHour, "mph", "Speed", "mph", "mi/h")
        add(UnitSpeed.metersPerSecond, "m/s", "Speed", "m/s", "mps")
        add(UnitSpeed.knots, "kn", "Speed", "kn", "knot")

        add(UnitArea.squareMeters, "m²", "Area", "m2", "m²", "sqm", "squaremeter", "squaremetre")
        add(UnitArea.squareKilometers, "km²", "Area", "km2", "km²", "sqkm")
        add(UnitArea.squareFeet, "ft²", "Area", "ft2", "ft²", "sqft", "squarefoot", "squarefeet")
        add(UnitArea.squareMiles, "mi²", "Area", "mi2", "sqmi", "squaremile")
        add(UnitArea.acres, "acres", "Area", "acre")
        add(UnitArea.hectares, "ha", "Area", "ha", "hectare")

        add(UnitInformationStorage.bytes, "B", "Data", "b", "byte")
        add(UnitInformationStorage.kilobytes, "KB", "Data", "kb", "kilobyte")
        add(UnitInformationStorage.megabytes, "MB", "Data", "mb", "megabyte")
        add(UnitInformationStorage.gigabytes, "GB", "Data", "gb", "gigabyte")
        add(UnitInformationStorage.terabytes, "TB", "Data", "tb", "terabyte")
        add(UnitInformationStorage.kibibytes, "KiB", "Data", "kib")
        add(UnitInformationStorage.mebibytes, "MiB", "Data", "mib")
        add(UnitInformationStorage.gibibytes, "GiB", "Data", "gib")

        add(UnitDuration.milliseconds, "ms", "Time", "ms", "millisecond")
        add(UnitDuration.seconds, "s", "Time", "s", "sec", "second")
        add(UnitDuration.minutes, "min", "Time", "min", "minute")
        add(UnitDuration.hours, "h", "Time", "h", "hr", "hour")
        // Foundation has no day / week unit: built from seconds.
        add(UnitDuration(symbol: "days", converter: UnitConverterLinear(coefficient: 86_400)), "days", "Time", "d", "day")
        add(UnitDuration(symbol: "weeks", converter: UnitConverterLinear(coefficient: 604_800)), "weeks", "Time", "wk", "week")
        return table
    }()

    // MARK: - Currency

    private static let currencyNames: [String: String] = [
        "dollar": "USD", "buck": "USD", "euro": "EUR", "pound": "GBP", "quid": "GBP", "sterling": "GBP",
        "yen": "JPY", "rupee": "INR", "franc": "CHF", "yuan": "CNY", "rmb": "CNY", "won": "KRW",
        "peso": "MXN", "real": "BRL", "rand": "ZAR", "lira": "TRY", "zloty": "PLN", "krona": "SEK",
        "krone": "NOK", "shekel": "ILS", "baht": "THB", "ringgit": "MYR", "rupiah": "IDR",
    ]

    /// A currency code for `name` ("usd", "$", "pounds"), if the rate table prices it.
    /// `strict`: only a sign or an ISO code, for the connector-less form ("100 usd"), where a
    /// plain word like "real" must stay a search.
    private static func currency(_ name: String, _ rates: CurrencyRates.Snapshot, strict: Bool = false) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces)
        if key.count == 1, let sign = key.first, let code = signs[sign] { return code.uppercased() }
        let upper = key.uppercased()
        if upper.count == 3, rates.perEuro[upper] != nil { return upper }
        guard !strict else { return nil }
        let single = key.hasSuffix("s") ? String(key.dropLast()) : key
        if let code = currencyNames[key] ?? currencyNames[single], rates.perEuro[code] != nil { return code }
        return nil
    }

    private static func money(_ amount: Double, from: String, to: String, rates: CurrencyRates.Snapshot) -> Result? {
        guard let source = rates.perEuro[from], let target = rates.perEuro[to], source > 0 else { return nil }
        let value = amount / source * target
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = to
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(number(value)) \(to)"
        return Result(output: text, detail: "\(from) → \(to) · ECB rate, \(rates.day)")
    }

    /// Up to 4 decimals for small values, 2 otherwise, no trailing zeros.
    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 1 ? 4 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// The ECB's daily reference rates (units of each currency per one euro), cached on disk.
nonisolated final class CurrencyRates: @unchecked Sendable {
    static let shared = CurrencyRates()

    struct Snapshot: Codable, Sendable {
        /// "19 Nov"
        var day: String
        var fetched: Date
        var perEuro: [String: Double]
    }

    private let lock = NSLock()
    private var current: Snapshot?
    private var loadedFromDisk = false
    private var refreshing = false

    private static var file: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.cavaldos.Lumio/ecb-rates.json")
    }

    /// The last known rates (from memory or disk), nil before the first successful fetch.
    var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        if !loadedFromDisk {
            loadedFromDisk = true
            if let data = try? Data(contentsOf: Self.file) {
                current = try? JSONDecoder().decode(Snapshot.self, from: data)
            }
        }
        return current
    }

    /// Fetches new rates when the stored ones are older than 12 hours. Safe to call on every open.
    func refreshIfStale() {
        let existing = snapshot
        if let existing, Date().timeIntervalSince(existing.fetched) < 12 * 3600 { return }
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        Task.detached(priority: .utility) {
            let fresh = await Self.fetch()
            self.finish(fresh)
        }
    }

    private func finish(_ fresh: Snapshot?) {
        lock.lock()
        refreshing = false
        if let fresh { current = fresh }
        lock.unlock()
        guard let fresh, let data = try? JSONEncoder().encode(fresh) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    private static func fetch() async -> Snapshot? {
        guard let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Lumio", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(xml)
    }

    /// `<Cube time='2026-11-19'> <Cube currency='USD' rate='1.0992'/> …`
    static func parse(_ xml: String) -> Snapshot? {
        var rates: [String: Double] = ["EUR": 1]
        var day = ""
        for piece in xml.components(separatedBy: "<Cube ").dropFirst() {
            func attribute(_ name: String) -> String? {
                guard let start = piece.range(of: name + "='") else { return nil }
                let rest = piece[start.upperBound...]
                guard let end = rest.firstIndex(of: "'") else { return nil }
                return String(rest[..<end])
            }
            if let time = attribute("time") { day = time }
            if let code = attribute("currency"), let rate = attribute("rate").flatMap(Double.init) {
                rates[code.uppercased()] = rate
            }
        }
        guard rates.count > 5 else { return nil }
        // "2026-11-19" → "19 Nov"
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        input.locale = Locale(identifier: "en_US_POSIX")
        let output = DateFormatter()
        output.dateFormat = "d MMM"
        let label = input.date(from: day).map(output.string(from:)) ?? day
        return Snapshot(day: label, fetched: Date(), perEuro: rates)
    }
}
