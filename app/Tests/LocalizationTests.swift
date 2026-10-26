import XCTest

final class LocalizationTests: XCTestCase {
    func testBothLanguagesHaveCompleteStringsAndMatchingFormatArguments() throws {
        let english = try strings(language: "en", table: "Localizable")
        let russian = try strings(language: "ru", table: "Localizable")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        let formats = try NSRegularExpression(pattern: #"%(?:\d+\$)?[@df]"#)
        for (key, value) in english {
            let translated = try XCTUnwrap(russian[key])
            XCTAssertFalse(translated.isEmpty, key)
            func arguments(_ text: String) -> [String] {
                formats.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                    String(text[Range($0.range, in: text)!])
                }.sorted()
            }
            XCTAssertEqual(arguments(value), arguments(translated), key)
        }
        for language in ["en", "ru"] {
            let privacy = try strings(language: language, table: "InfoPlist")
            XCTAssertFalse(try XCTUnwrap(privacy["NSPhotoLibraryUsageDescription"]).isEmpty)
            XCTAssertFalse(try XCTUnwrap(privacy["NSPhotoLibraryAddUsageDescription"]).isEmpty)
        }
    }

    func testPackagedBundleSupportsRussianAndEnglishFallback() {
        let bundle = L10n.bundle
        XCTAssertEqual(bundle.developmentLocalization, "en")
        XCTAssertTrue(Set(bundle.localizations).isSuperset(of: ["en", "ru"]))
        XCTAssertEqual(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["ru-RU"]).first, "ru")
        XCTAssertEqual(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["en-GB"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["fr-FR"]).first, "en")
    }

    private func strings(language: String, table: String) throws -> [String: String] {
        let folder = try XCTUnwrap(L10n.bundle.url(forResource: language, withExtension: "lproj"))
        let data = try Data(contentsOf: folder.appendingPathComponent("\(table).strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
