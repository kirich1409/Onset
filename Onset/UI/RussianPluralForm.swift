// MARK: - RussianPluralForm

/// Pure, nonisolated helper for selecting Russian plural forms.
///
/// Russian pluralization depends on the last two digits of a number:
///   - Ends in 1 (not 11) → singular form (один кадр).
///   - Ends in 2–4 (not 12–14) → paucal form (два кадра).
///   - All other cases (including 11–14) → genitive-plural form (пять кадров).
///
/// Use `select(count:one:few:many:)` when the caller supplies all three forms.
/// The same category logic applies to verb agreement:
/// "Пропущен 1 кадр" / "Пропущено 2 кадра" / "Пропущено 5 кадров".
/// Pass the verb forms as `one:few:many:` just as you would for a noun.
///
/// ### References
/// Pluralization rules: CLDR Plural Rules for Russian language (ru).
nonisolated enum RussianPluralForm {
    // MARK: - Core selector

    // swiftlint:disable no_magic_numbers
    /// Selects the correct Russian plural form for `count`.
    ///
    /// - Parameters:
    ///   - count: The non-negative integer to pluralize.
    ///   - one:   Form used when count ends in 1 (excl. 11): «кадр», «Пропущен».
    ///   - few:   Form used when count ends in 2–4 (excl. 12–14): «кадра», «Пропущено».
    ///   - many:  Form used in all other cases (0, 5–20, 11–14, …): «кадров», «Пропущено».
    nonisolated static func select(count: Int, one: String, few: String, many: String) -> String {
        let lastTwo = count % 100
        let lastOne = count % 10
        if lastTwo >= 11, lastTwo <= 14 {
            return many
        }
        switch lastOne {
        case 1:
            return one

        case 2, 3, 4:
            return few

        default:
            return many
        }
    }

    // swiftlint:enable no_magic_numbers
}
