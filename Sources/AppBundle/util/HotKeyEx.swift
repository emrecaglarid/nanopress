import HotKey

extension HotKey {
    /// Unregisters the key explicitly. Dropping the HotKey object doesn't, while its handler is running
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}
