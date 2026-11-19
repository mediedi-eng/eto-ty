import Foundation

/// Suggests an editable local time for common Russian reminder phrases.
/// Only the date picker can commit the suggestion to a care plan.
enum ContactTimeSuggestion {
    static func parse(_ text: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard words.count <= 1_000,
              words.range(of: #"\b(напомни|напомнить|спроси|перенеси|перенести|вернемся|напиши)\b"#, options: .regularExpression) != nil,
              words.range(of: #"\b(не|или|если|кроме|после|до)\b"#, options: .regularExpression) == nil
        else { return nil }

        if let parts = matches(#"\bчерез\s+(\d{1,3}|одну|один|два|две|три|пять|десять)\s+(минуту|минуты|минут|час|часа|часов|день|дня|дней)\b"#, in: words) {
            let numbers = ["одну": 1, "один": 1, "два": 2, "две": 2, "три": 3, "пять": 5, "десять": 10]
            guard let amount = Int(parts[0]) ?? numbers[parts[0]], amount > 0 else { return nil }
            let unit: Calendar.Component = parts[1].hasPrefix("минут") ? .minute : (parts[1].hasPrefix("час") ? .hour : .day)
            return calendar.date(byAdding: unit, value: amount, to: now)
        }

        let pattern = #"\b(сегодня|завтра|послезавтра|понедельник|вторник|среду|четверг|пятницу|субботу|воскресенье)\s+в\s+(\d{1,2})(?:[:.](\d{2}))?(?![:.\d])\b"#
        guard let parts = matches(pattern, in: words), let hour = Int(parts[1]), hour < 24 else { return nil }
        let minutes = Int(parts[2]) ?? 0
        guard minutes < 60 else { return nil }
        let weekdays = ["воскресенье", "понедельник", "вторник", "среду", "четверг", "пятницу", "субботу"]
        let offset: Int
        if let weekday = weekdays.firstIndex(of: parts[0]) {
            offset = (weekday + 1 - calendar.component(.weekday, from: now) + 7) % 7
        } else {
            offset = parts[0] == "сегодня" ? 0 : (parts[0] == "завтра" ? 1 : 2)
        }
        guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minutes
        guard let proposed = calendar.date(from: components),
              calendar.component(.hour, from: proposed) == hour, proposed > now else { return nil }
        return proposed
    }

    private static func matches(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        let results = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard results.count == 1, let result = results.first else { return nil }
        return (1..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}
