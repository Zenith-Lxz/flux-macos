/// Frozen bundle metadata for the Flux application.
///
/// Contract (design spec §7.1): the bundle identifier, executable name, and
/// minimum system version are fixed. `scripts/build-app.sh` and the generated
/// `Info.plist` must match these values; `AppMetadataTests` pins the contract.
public struct AppMetadata: Sendable, Equatable {
    public let bundleIdentifier: String
    public let appName: String
    public let executableName: String
    public let version: String
    public let minimumSystemVersion: String

    public init(
        bundleIdentifier: String,
        appName: String,
        executableName: String,
        version: String,
        minimumSystemVersion: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.executableName = executableName
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// The metadata the v1 bundle must be built with.
    public static let current = AppMetadata(
        bundleIdentifier: "com.zenith.flux",
        appName: "Flux",
        executableName: "FluxApp",
        version: "1.0.0",
        minimumSystemVersion: "13.0"
    )
}
