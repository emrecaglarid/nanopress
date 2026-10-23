public let stableAeroSpaceAppId: String = "io.github.emrecaglarid.nanopress"
#if DEBUG
    public let aeroSpaceAppId: String = "io.github.emrecaglarid.nanopress.debug"
    public let aeroSpaceAppName: String = "nanopress-debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "nanopress"
#endif
