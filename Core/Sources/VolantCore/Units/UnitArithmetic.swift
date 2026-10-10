import Foundation

/// Arithmetic on quantities with units, beyond the single conversions `UnitConverter` answers:
/// sums and differences ("5 km + 300 m", "2 lb - 3 oz"), mixed quantities with a target ("5 ft 10 in
/// in cm", "5'10\" in cm"), scaling ("5 km * 3", "10 mi / 4"), ratios of like quantities ("10 km /
/// 2 km"), and speeds or data rates from a quantity over a time ("1 mile / 8 min in kph", "1 GB / 10 s
/// in Mbps"). Parentheses group arithmetic with the usual precedence ("(3kg + 5lbs) * 2 in oz",
/// "2 * (1 ft + 6 in) in cm"), and a product binds before a sum, so "5 km + 300 m * 3" is 5.9 km.
///
/// A sum answers in its first unit unless a target follows "in", "to" or "as". Mixed quantities with
/// no operator need a target, so a bare "5 ft 10 in" stays a search. A speed with no target answers
/// in mph after imperial lengths and km/h otherwise; a data rate in Mbps. Sums of durations alone are
/// left to `DateCalculator`, and offset scales (temperature) and reciprocal units (fuel economy, pace)
/// do not add.
public enum UnitArithmetic {
    private typealias Spec = UnitConverter.Spec

    private struct Term {
        let value: Double
        let spec: Spec
    }

    private enum Operation {
        case scale(Double)
        case per([Term])
    }

    public static func evaluate(_ text: String, locale: Locale = .current) -> CalculationAnswer? {
        guard text.utf8.count <= 256 else { return nil }
        let input = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var query = UnitConverter.normalized(text)
        query = query.replacingOccurrences(of: #"([+*×])"#, with: " $1 ", options: .regularExpression)
        query = query.replacingOccurrences(of: #"(?<=[a-z\.)])-(?=\s*[\d(])"#, with: " - ", options: .regularExpression)
        query = query.replacingOccurrences(of: #"(?<=\))\s*/|/(?=\s*\()"#, with: " / ", options: .regularExpression)
        query = query.replacingOccurrences(of: #"([()])"#, with: " $1 ", options: .regularExpression)
        var words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var target: Spec?
        if let index = words.lastIndex(where: { ["in", "to", "as"].contains($0) }), index + 1 < words.count,
           let spec = UnitConverter.lookup(words[(index + 1)...].joined()) {
            target = spec
            words.removeSubrange(index...)
        }
        let separators = NumberLiteral.Separators(locale)
        if words.contains(where: { $0 == "(" || $0 == ")" }) {
            return grouped(words, target: target, input: input, separators, locale: locale)
        }
        var index = 0
        guard let (numerator, explicit) = sum(words, &index, separators), !numerator.isEmpty else { return nil }
        var operation: Operation?
        if index < words.count {
            let word = words[index]
            index += 1
            guard ["*", "x", "×", "times", "/"].contains(word), index < words.count else { return nil }
            if index + 1 == words.count, let factor = NumberLiteral.parse(words[index], locale: locale, magnitudes: false) {
                guard word != "/" || factor != 0 else { return nil }
                operation = .scale(word == "/" ? 1 / factor : factor)
                index += 1
            } else if word == "/", let (denominator, _) = sum(words, &index, separators), index == words.count {
                operation = .per(denominator)
            } else {
                return nil
            }
        }
        if explicit, operation != nil {
            return grouped(words, target: target, input: input, separators, locale: locale)
        }
        guard numerator.count >= 2 || operation != nil, explicit || operation != nil || target != nil else { return nil }
        guard let (total, unit) = combine(numerator) else { return nil }
        let value: Double, result: Spec
        switch operation {
        case .per(let denominator)?:
            guard let (over, overUnit) = combine(denominator), over != 0 else { return nil }
            if UnitConverter.sameDimension(unit.unit, overUnit.unit) {
                guard target == nil else { return nil }
                let ratio = total / UnitConverter.convert(over, from: overUnit.unit, to: unit.unit)
                guard ratio.isFinite else { return nil }
                let text = Calculator.format((ratio * 1e6).rounded() / 1e6, locale: locale)
                return CalculationAnswer(input: input, inputDetail: nil, result: text, resultDetail: nil, copyText: text)
            }
            guard let rate = perTime(total, unit, over, overUnit) else { return nil }
            result = target ?? rate.fallback
            guard UnitConverter.sameDimension(result.unit, rate.unit) else { return nil }
            value = UnitConverter.convert(rate.value, from: rate.unit, to: result.unit)
        default:
            guard !(unit.unit is UnitDuration) else { return nil }
            var scaled = total
            if case .scale(let factor)? = operation { scaled *= factor }
            result = target ?? unit
            guard UnitConverter.sameDimension(result.unit, unit.unit) else { return nil }
            value = UnitConverter.convert(scaled, from: unit.unit, to: result.unit)
        }
        guard value.isFinite else { return nil }
        let text = "\(Calculator.format((value * 1e6).rounded() / 1e6, locale: locale)) \(result.symbol)"
        return CalculationAnswer(input: input, inputDetail: nil, result: text,
                                 resultDetail: CalculationAnswer.unitName(result.unit, locale: locale), copyText: text)
    }

    /// Quantities joined by "+", "-" or nothing ("5 ft 10 in"), starting at `index` and leaving it
    /// after the last one. `explicit` says whether any operator joined them.
    private static func sum(_ words: [String], _ index: inout Int, _ separators: NumberLiteral.Separators) -> ([Term], Bool)? {
        var terms: [Term] = [], sign = 1.0, explicit = false
        if index < words.count, words[index] == "-" {
            sign = -1
            index += 1
        }
        while index < words.count {
            guard let term = term(words, &index, separators) else { return nil }
            terms.append(Term(value: sign * term.value, spec: term.spec))
            sign = 1
            guard index < words.count else { break }
            if words[index] == "+" || words[index] == "-" {
                sign = words[index] == "+" ? 1 : -1
                explicit = true
                index += 1
                guard index < words.count else { return nil }
            } else if !(words[index].first?.isNumber ?? false) {
                break
            }
        }
        return terms.isEmpty ? nil : (terms, explicit)
    }

    /// A number and its unit, which may touch ("300m") or span words ("fl oz", "square feet").
    private static func term(_ words: [String], _ index: inout Int, _ separators: NumberLiteral.Separators) -> Term? {
        let chars = Array(words[index])
        guard let (value, end) = NumberLiteral.scan(chars, from: 0, separators, magnitudes: false) else { return nil }
        let attached = String(chars[end...])
        let operators: Set<String> = ["+", "-", "*", "x", "×", "/", "times", "(", ")"]
        var longest: (Spec, Int)?
        for extra in 0...3 where index + extra < words.count {
            let following = words[(index + 1)..<(index + 1 + extra)]
            guard !following.contains(where: { operators.contains($0) || ($0.first?.isNumber ?? false) }) else { break }
            if let spec = UnitConverter.lookup(attached + following.joined()) { longest = (spec, extra) }
        }
        guard let (spec, extra) = longest else { return nil }
        index += 1 + extra
        return Term(value: value, spec: spec)
    }

    /// A length or amount of data over a time, as a speed in m/s or a data rate in bits per second,
    /// with the unit it answers in when no target is given: mph after imperial lengths, km/h after
    /// other lengths, and Mbps for data. Anything else over a time, or a zero time, has no rate.
    private static func perTime(_ total: Double, _ unit: Spec, _ over: Double, _ overUnit: Spec)
        -> (value: Double, unit: Dimension, fallback: Spec)? {
        guard overUnit.unit is UnitDuration else { return nil }
        let seconds = UnitConverter.convert(over, from: overUnit.unit, to: UnitDuration.seconds)
        guard seconds != 0 else { return nil }
        switch unit.unit {
        case is UnitLength:
            let imperial = ["mi", "ft", "yd", "in"].contains(unit.symbol)
            let fallback = Spec(unit: imperial ? UnitSpeed.milesPerHour : UnitSpeed.kilometersPerHour, symbol: imperial ? "mph" : "km/h")
            return (UnitConverter.convert(total, from: unit.unit, to: UnitLength.meters) / seconds, UnitSpeed.metersPerSecond, fallback)
        case is UnitInformationStorage:
            let fallback = Spec(unit: UnitConverter.Extra.megabitsPerSecond, symbol: "Mbps")
            return (UnitConverter.convert(total, from: unit.unit, to: UnitInformationStorage.bits) / seconds,
                    UnitConverter.Extra.bitsPerSecond, fallback)
        default:
            return nil
        }
    }

    /// The total of like, linear quantities in the first one's unit.
    private static func combine(_ terms: [Term]) -> (Double, Spec)? {
        guard let first = terms.first, UnitConverter.factor(first.spec.unit) != nil else { return nil }
        var total = 0.0
        for term in terms {
            guard UnitConverter.sameDimension(term.spec.unit, first.spec.unit), UnitConverter.factor(term.spec.unit) != nil else { return nil }
            total += UnitConverter.convert(term.value, from: term.spec.unit, to: first.spec.unit)
        }
        return (total, first.spec)
    }

    /// Answers an expression with parentheses, such as "(3kg + 5lbs) * 2 in oz" or "2 * (1 ft + 6 in)
    /// in cm". Like the flat forms it needs an operator, or a target after mixed quantities, and at
    /// least one quantity, so "(2 + 3) * 4" stays with `Calculator`. The answer is in the first unit
    /// read unless a target follows; a ratio of like quantities is a plain number and takes no target.
    private static func grouped(_ words: [String], target: Spec?, input: String, _ separators: NumberLiteral.Separators,
                                locale: Locale) -> CalculationAnswer? {
        var parser = Grouped(words: words, separators: separators, locale: locale)
        guard let amount = parser.expression(), parser.index == words.count, parser.quantities > 0,
              parser.operators > 0 || (parser.adjacent && target != nil) else { return nil }
        guard let spec = amount.spec else {
            guard target == nil, amount.value.isFinite else { return nil }
            let text = Calculator.format((amount.value * 1e6).rounded() / 1e6, locale: locale)
            return CalculationAnswer(input: input, inputDetail: nil, result: text, resultDetail: nil, copyText: text)
        }
        guard !(spec.unit is UnitDuration) else { return nil }
        let result = target ?? spec
        guard UnitConverter.sameDimension(result.unit, spec.unit) else { return nil }
        let value = UnitConverter.convert(amount.value, from: spec.unit, to: result.unit)
        guard value.isFinite else { return nil }
        let text = "\(Calculator.format((value * 1e6).rounded() / 1e6, locale: locale)) \(result.symbol)"
        return CalculationAnswer(input: input, inputDetail: nil, result: text,
                                 resultDetail: CalculationAnswer.unitName(result.unit, locale: locale), copyText: text)
    }

    /// A number, or a quantity in `spec`'s unit.
    private struct Amount {
        let value: Double
        let spec: Spec?
    }

    /// A recursive-descent reader for grouped unit expressions. Sums sit below products, products
    /// below signs, and parentheses or quantities at the bottom. Every step checks dimensions: like
    /// quantities add and divide into a number, numbers scale quantities, and anything else (a
    /// quantity plus a number, a product of quantities, a quantity over another kind) has no answer.
    /// Only linear units take part, so temperatures and reciprocal units never combine.
    private struct Grouped {
        let words: [String]
        let separators: NumberLiteral.Separators
        let locale: Locale
        var index = 0
        var quantities = 0
        var operators = 0
        var adjacent = false
        var depth = 0

        init(words: [String], separators: NumberLiteral.Separators, locale: Locale) {
            self.words = words
            self.separators = separators
            self.locale = locale
        }

        /// Products joined by "+" or "-".
        mutating func expression() -> Amount? {
            guard var total = product() else { return nil }
            while index < words.count, words[index] == "+" || words[index] == "-" {
                let sign = words[index] == "+" ? 1.0 : -1.0
                index += 1
                operators += 1
                guard let next = product(), let sum = Self.add(total, next, sign) else { return nil }
                total = sum
            }
            return total
        }

        /// Signed factors joined by "*", "x", "×", "times" or "/".
        mutating func product() -> Amount? {
            guard var total = signed() else { return nil }
            while index < words.count, ["*", "x", "×", "times", "/"].contains(words[index]) {
                let divide = words[index] == "/"
                index += 1
                operators += 1
                guard let next = signed(), let result = divide ? Self.divide(total, next) : Self.multiply(total, next) else { return nil }
                total = result
            }
            return total
        }

        /// A factor with optional leading minus signs.
        mutating func signed() -> Amount? {
            var sign = 1.0
            while index < words.count, words[index] == "-" {
                sign = -sign
                index += 1
            }
            return factor().map { Amount(value: sign * $0.value, spec: $0.spec) }
        }

        /// A parenthesized expression, a quantity (with any quantities that follow it unjoined, as in
        /// "5 ft 10 in"), or a plain number. Nesting is capped so hostile input cannot recurse deeply.
        mutating func factor() -> Amount? {
            guard index < words.count else { return nil }
            if words[index] == "(" {
                guard depth < 16 else { return nil }
                index += 1
                depth += 1
                guard let inner = expression(), index < words.count, words[index] == ")" else { return nil }
                index += 1
                depth -= 1
                return inner
            }
            if var total = quantity() {
                while index < words.count, words[index].first?.isNumber ?? false {
                    guard let next = quantity(), let sum = Self.add(total, next, 1) else { return nil }
                    adjacent = true
                    total = sum
                }
                return total
            }
            guard let value = NumberLiteral.parse(words[index], locale: locale, magnitudes: false) else { return nil }
            index += 1
            return Amount(value: value, spec: nil)
        }

        /// One number and its linear unit, read by `term`.
        mutating func quantity() -> Amount? {
            var next = index
            guard let term = UnitArithmetic.term(words, &next, separators), UnitConverter.factor(term.spec.unit) != nil else { return nil }
            index = next
            quantities += 1
            return Amount(value: term.value, spec: term.spec)
        }

        /// A sum of two numbers, or of two like quantities in the first one's unit.
        static func add(_ a: Amount, _ b: Amount, _ sign: Double) -> Amount? {
            switch (a.spec, b.spec) {
            case (nil, nil):
                return Amount(value: a.value + sign * b.value, spec: nil)
            case let (first?, second?) where UnitConverter.sameDimension(first.unit, second.unit):
                return Amount(value: a.value + sign * UnitConverter.convert(b.value, from: second.unit, to: first.unit), spec: first)
            default:
                return nil
            }
        }

        /// A product with at most one quantity, keeping its unit.
        static func multiply(_ a: Amount, _ b: Amount) -> Amount? {
            guard a.spec == nil || b.spec == nil else { return nil }
            return Amount(value: a.value * b.value, spec: a.spec ?? b.spec)
        }

        /// A quantity or number over a non-zero number, a ratio of like quantities, or a speed or data
        /// rate from a quantity over a time, held in the unit it answers in without a target.
        static func divide(_ a: Amount, _ b: Amount) -> Amount? {
            switch (a.spec, b.spec) {
            case (_, nil):
                guard b.value != 0 else { return nil }
                return Amount(value: a.value / b.value, spec: a.spec)
            case let (first?, second?) where UnitConverter.sameDimension(first.unit, second.unit):
                let over = UnitConverter.convert(b.value, from: second.unit, to: first.unit)
                guard over != 0 else { return nil }
                return Amount(value: a.value / over, spec: nil)
            case let (first?, second?):
                guard let rate = UnitArithmetic.perTime(a.value, first, b.value, second) else { return nil }
                return Amount(value: UnitConverter.convert(rate.value, from: rate.unit, to: rate.fallback.unit), spec: rate.fallback)
            default:
                return nil
            }
        }
    }
}
