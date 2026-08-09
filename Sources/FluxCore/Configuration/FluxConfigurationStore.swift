import Foundation

/// Versioned, atomic configuration store (design spec §9).
///
/// `load()` never throws and never mutates disk; `save(_:)` writes a
/// sanitized, deterministically ordered v1 document atomically in the
/// destination directory and applies restrictive file protection (0700
/// directory, 0600 file) without ever weakening stricter pre-existing
/// permissions.
public struct FluxConfigurationStore: Sendable {
    /// Destination for the versioned configuration document.
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The canonical on-disk location:
    /// `~/Library/Application Support/Flux/config.json`.
    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return supportDirectory
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// Loads the configuration without throwing and without touching disk:
    /// missing → default/missing; malformed or type-invalid → default/corrupt;
    /// schemaVersion > 1 → default/unsupported future; v0 → migrated; v1 →
    /// decoded and sanitized. Versions < 0 and any other non-0/non-1 value are
    /// corrupt.
    public func load() -> ConfigurationLoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ConfigurationLoadResult(configuration: .default, source: .missingDefault)
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return ConfigurationLoadResult(configuration: .default, source: .corruptDefault)
        }
        switch probe.effectiveVersion {
        case nil:
            return ConfigurationLoadResult(configuration: .default, source: .corruptDefault)
        case let version? where version < 0:
            return ConfigurationLoadResult(configuration: .default, source: .corruptDefault)
        case 0:
            guard let legacy = try? JSONDecoder().decode(LegacyV0Configuration.self, from: data) else {
                return ConfigurationLoadResult(configuration: .default, source: .corruptDefault)
            }
            return ConfigurationLoadResult(configuration: legacy.migrated(), source: .migratedV0)
        case 1:
            guard let decoded = try? JSONDecoder().decode(FluxConfiguration.self, from: data) else {
                return ConfigurationLoadResult(configuration: .default, source: .corruptDefault)
            }
            return ConfigurationLoadResult(configuration: decoded.sanitized(), source: .currentFile)
        default:
            return ConfigurationLoadResult(configuration: .default, source: .unsupportedFutureVersionDefault)
        }
    }

    /// Writes a sanitized v1 document: creates the Flux directory, encodes
    /// with sorted keys, appends a trailing newline, writes atomically in the
    /// destination directory, and applies 0700/0600 protection without
    /// weakening stricter pre-existing permissions. The store serializes only
    /// the public configuration model — never credentials.
    public func save(_ configuration: FluxConfiguration) throws {
        let sanitized = configuration.sanitized()
        let directory = fileURL.deletingLastPathComponent()
        let previousDirectoryPerms = Self.existingPosixPermissions(of: directory)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.tightenPermissionsIfNeeded(
            at: directory,
            maximum: 0o700,
            previous: previousDirectoryPerms
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(sanitized)
        data.append(0x0A)

        let previousFilePerms = Self.existingPosixPermissions(of: fileURL)
        try data.write(to: fileURL, options: [.atomic])
        try Self.tightenPermissionsIfNeeded(
            at: fileURL,
            maximum: 0o600,
            previous: previousFilePerms
        )
    }
}

extension FluxConfigurationStore {
    /// Reads either the v0 `version` key or the v1 `schemaVersion` key and
    /// resolves conflicts deterministically.
    private struct VersionProbe: Decodable {
        let version: Int?
        let schemaVersion: Int?

        /// nil when both keys are absent or disagree; otherwise the single
        /// declared version.
        var effectiveVersion: Int? {
            switch (version, schemaVersion) {
            case (nil, nil):
                return nil
            case (let version?, nil):
                return version
            case (nil, let schemaVersion?):
                return schemaVersion
            case (let version?, let schemaVersion?) where version == schemaVersion:
                return version
            case (_, _):
                return nil
            }
        }
    }

    private static func existingPosixPermissions(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue & 0o777
    }

    /// Removes every permission bit that is absent from either the security
    /// ceiling or the pre-write mode. Bitwise intersection matters here:
    /// numeric ordering does not describe permission strictness (`0507` is
    /// numerically below `0600` while still exposing access to other users).
    private static func tightenPermissionsIfNeeded(
        at url: URL,
        maximum: Int,
        previous: Int?
    ) throws {
        guard let current = existingPosixPermissions(of: url) else { return }
        let tightened = current & maximum & (previous ?? maximum)
        guard current != tightened else { return }
        try FileManager.default.setAttributes([.posixPermissions: tightened], ofItemAtPath: url.path)
    }
}
