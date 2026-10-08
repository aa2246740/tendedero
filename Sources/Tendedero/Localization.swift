import Foundation

/// Resolves once: the first of the user's preferred languages we speak.
/// English is the source-of-truth fallback, so it needs no dictionary key.
private let language: String = {
    for preferred in Locale.preferredLanguages {
        let code = preferred.lowercased()
        if code.hasPrefix("zh") {
            // Traditional script and regions get their own strings;
            // everything else Chinese falls to Simplified.
            return code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw")
                || code.hasPrefix("zh-hk") || code.hasPrefix("zh-mo")
                ? "zh-Hant" : "zh"
        }
        if code.hasPrefix("es") { return "es" }
        if code.hasPrefix("en") { return "en" }
    }
    return "en"
}()

/// Tiny localization helper. The app has a handful of strings, so a full
/// .strings setup would be more ceremony than content: English is the
/// fallback, every other language rides in the dictionary — adding one
/// means adding a key, not touching call sites' shape.
func L(_ english: String, _ others: [String: String] = [:]) -> String {
    others[language] ?? english
}
