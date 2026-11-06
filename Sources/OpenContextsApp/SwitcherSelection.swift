/// Selection arithmetic for the window switcher's result list.
enum SwitcherSelection {
    /// The row selected when the switcher opens: the last one when switching backward, otherwise the second one
    /// when the first is the window that already has focus.
    static func initial(count: Int, firstIsFocused: Bool, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        if reverse { return count - 1 }
        return firstIsFocused ? min(1, count - 1) : 0
    }

    /// Moves `amount` rows from `index`, wrapping around in both directions.
    static func stepped(_ index: Int, by amount: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let wrapped = (index % count + amount % count) % count
        return wrapped < 0 ? wrapped + count : wrapped
    }

    /// The row of `selectedID` when it is still listed, otherwise `fallback` clamped to the list.
    static func preserved(_ selectedID: String?, in ids: [String], fallback: Int) -> Int {
        if let selectedID, let index = ids.firstIndex(of: selectedID) { return index }
        return min(max(fallback, 0), max(0, ids.count - 1))
    }
}
