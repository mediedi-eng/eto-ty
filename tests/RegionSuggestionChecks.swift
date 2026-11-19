import Foundation

enum RegionSuggestionChecks {
    static func run() {
        typealias Hint = CareRegionSuggestion.Hint
        func check(_ name: String, _ quote: String?, _ page: Int?, _ expected: Hint?) {
            precondition(CareRegionSuggestion.hint(name: name, quote: quote, page: page) == expected)
        }
        check("IMG_0042.jpg", " УЗИ   почек ", 1, Hint(region: .kidneys, quotePage: 1))
        check("scan.pdf", "Echocardiogram", 3, Hint(region: .heart, quotePage: 3))
        check("Liver.pdf", "УЗИ печени", 2, Hint(region: .liver, quotePage: 2))
        check("ecg.pdf", nil, nil, Hint(region: .heart, quotePage: nil))
        check("IMG_0042.jpg", "УЗИ почек", nil, nil)
        check("IMG_0042.jpg", "УЗИ почек", 0, nil)
        check("scan.pdf", "УЗИ почек не выполнялось", 1, nil)
        check("scan.pdf", "Рекомендована ЭКГ", 1, nil)
        check("ЭКГ.pdf", "УЗИ почек", 1, nil)
        check("Почки-и-печень.pdf", "УЗИ почек", 1, nil)
        check("ЭКГ.pdf", "Выполнено УЗИ почек и печени", 1, nil)
    }
}
