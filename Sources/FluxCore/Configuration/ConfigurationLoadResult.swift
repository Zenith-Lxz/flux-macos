/// Where a loaded configuration came from (design spec §9).
public enum ConfigurationSource: String, Sendable, Equatable, CaseIterable {
    /// A valid v1 file was decoded and sanitized from disk.
    case currentFile
    /// A v0 legacy file was deterministically migrated to the current schema.
    case migratedV0
    /// No file existed; the returned configuration is the built-in default.
    case missingDefault
    /// The file could not be parsed or validated; the default is returned.
    case corruptDefault
    /// The file declares a future schema version this build cannot read.
    case unsupportedFutureVersionDefault
}

/// Result of a non-throwing store load: the effective configuration plus the
/// source/status that produced it.
public struct ConfigurationLoadResult: Sendable, Equatable {
    public let configuration: FluxConfiguration
    public let source: ConfigurationSource

    public init(configuration: FluxConfiguration, source: ConfigurationSource) {
        self.configuration = configuration
        self.source = source
    }
}
