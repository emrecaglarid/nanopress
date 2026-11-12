extension Optional {
    public func orDie(
        _ message: String = "",
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> Wrapped {
        self ?? dieT("orDie: " + message, file: file, line: line, column: column, function: function)
    }

    public func flattenOptional<T>() -> T? where Wrapped == T? {
        switch self {
            case let x?: x
            case nil: nil
        }
    }

    public var prettyDescription: String {
        switch self {
            case let ok?: String(describing: ok)
            case nil: "nil"
        }
    }
}
