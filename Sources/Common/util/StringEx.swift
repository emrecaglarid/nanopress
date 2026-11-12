import Foundation

extension String: @retroactive LocalizedError { // Make it possible to use String in Result. todo migrate to self written Result monad
    public var errorDescription: String? { self }
}

// Make it possible to use [String] in Result. todo migrate to self written Result monad
extension Array: @retroactive Error where Element: Error {}
extension Array: @retroactive LocalizedError where Element: LocalizedError {}

extension String {
    public func prefixLines(with: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).map { with + $0 }.joined(separator: "\n")
    }

    public var singleQuoted: String { "'" + self + "'" }
    public var doubleQuoted: String { "\"" + self + "\"" }
}

extension [String] {
    public func joinTruncating(separator: String, length maxLength: Int, trailing: String = "…") -> String {
        if isEmpty {
            return ""
        }
        var remainingLen = maxLength
        let separatorCount = separator.count
        var result: String = first.orDie()
        for _elem in self.dropFirst() {
            let elemCount = separatorCount + _elem.count
            if remainingLen < elemCount / 2 {
                return result + separator + trailing
            }
            let elem = separator + _elem
            if elemCount < remainingLen {
                result += elem
                remainingLen -= elemCount
            } else {
                return result + elem.prefix(remainingLen) + trailing
            }
        }
        return result
    }
}
