import Foundation

// Bundle.main belongs to Photos when hosted as a project extension.
private final class LocalizationBundle: NSObject {}

enum L10n {
    static let bundle = Bundle(for: LocalizationBundle.self)
    static let locale: Locale = {
        let language = bundle.preferredLocalizations.first ?? "en"
        if Locale.current.language.languageCode?.identifier == language { return .current }
        return Locale(identifier: "\(language)_\(Locale.current.region?.identifier ?? "US")")
    }()

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    static func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
    static func date(_ value: Date?, complete: Bool = false, time: Bool = true) -> String {
        guard let value else { return text("Unknown date") }
        return value.formatted(Date.FormatStyle(date: complete ? .complete : .abbreviated,
                                                time: time ? .shortened : .omitted).locale(locale))
    }
    static func viewerDate(_ value: Date?) -> String {
        guard let value else { return text("Unknown date") }
        return value.formatted(.dateTime.day().month(.wide).year().hour().minute().second().locale(locale))
    }
}
