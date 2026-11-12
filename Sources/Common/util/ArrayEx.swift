extension Array {
    public func singleOrNil(where predicate: (Self.Element) throws -> Bool) rethrows -> Self.Element? {
        var found: Self.Element? = nil
        for elem in self where try predicate(elem) {
            switch found == nil {
                case true: found = elem
                case false: return nil
            }
        }
        return found
    }

    @discardableResult
    public mutating func remove(element: Self.Element) -> Int? where Self.Element: Equatable {
        switch firstIndex(of: element) {
            case nil: return nil
            case let index?:
                remove(at: index)
                return index
        }
    }
}

public func - <T>(lhs: [T], rhs: [T]) -> [T] where T: Hashable {
    let r = rhs.toSet()
    return lhs.filter { !r.contains($0) }
}
