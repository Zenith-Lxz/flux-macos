import Foundation
import Testing
@testable import FluxCore

// MARK: - Helpers

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FluxConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func posixPermissions(of path: String) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let number = attributes[.posixPermissions] as? NSNumber else { return nil }
    return number.intValue & 0o777
}

private func configStore(in directory: URL) -> FluxConfigurationStore {
    FluxConfigurationStore(fileURL: directory.appendingPathComponent("config.json"))
}

// MARK: - Default path contract

struct FluxConfigurationStoreDefaultPathTests {
    @Test func defaultFileURLResolvesToApplicationSupportFluxConfig() {
        let url = FluxConfigurationStore.defaultFileURL()
        #expect(url.lastPathComponent == "config.json")
        #expect(url.pathComponents.contains("Flux"))
        let expected = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("config.json")
        #expect(url == expected)
        // Must live under the user's home Library, never a system location.
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(url.path.hasPrefix(home.appendingPathComponent("Library/Application Support").path))
    }
}

// MARK: - Load sources

struct FluxConfigurationStoreLoadTests {
    @Test func missingFileReturnsDefaultAndCreatesNothing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = configStore(in: directory).load()

        #expect(result.source == .missingDefault)
        #expect(result.configuration == FluxConfiguration.default)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    @Test func corruptJSONReturnsCorruptDefaultAndDoesNotMutateFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let garbage = Data("not json at all {[".utf8)
        try garbage.write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
        let after = try Data(contentsOf: url)
        #expect(after == garbage)
    }

    @Test func typeInvalidJSONReturnsCorruptDefault() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"schemaVersion": 1, "enabled": "yes"}"#.utf8).write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
    }

    @Test func negativeVersionIsCorrupt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"version": -1, "enabled": true}"#.utf8).write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
    }

    @Test func conflictingVersionsAreCorrupt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"version": 0, "schemaVersion": 1}"#.utf8).write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
    }

    @Test func missingVersionIsCorrupt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"enabled": true}"#.utf8).write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
    }

    @Test func v1MissingRequiredFieldsIsCorrupt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"schemaVersion": 1}"#.utf8).write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .corruptDefault)
        #expect(result.configuration == FluxConfiguration.default)
    }

    @Test func futureVersionReturnsUnsupportedDefaultAndDoesNotMutateFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let future = Data(#"{"schemaVersion": 5, "enabled": false, "appearance": "solarized"}"#.utf8)
        try future.write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .unsupportedFutureVersionDefault)
        #expect(result.configuration == FluxConfiguration.default)
        let after = try Data(contentsOf: url)
        #expect(after == future)
    }

    @Test func v0FileMigratesWithoutMutatingDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let v0Data = Data(#"{"version": 0, "enabled": false, "apps": {"a": "com.example.ares"}, "pointerSpeed": 1.25}"#.utf8)
        try v0Data.write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .migratedV0)
        #expect(!result.configuration.enabled)
        #expect(result.configuration.applications.ares == "com.example.ares")
        #expect(result.configuration.applications.codex == AppBundleIdentifier.codex.rawValue)
        #expect(result.configuration.pointerSpeedMultiplier == 1.25)
        let after = try Data(contentsOf: url)
        #expect(after == v0Data)
    }

    @Test func v1FileLoadsAndSanitizesWithoutMutatingDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let json = #"{"schemaVersion": 1, "enabled": true, "applications": {"ares": null, "codex": "  com.example.codex  ", "chrome": "com.google.Chrome"}, "mappings": {"capsTextNavigationEnabled": true, "capsEditingEnabled": true, "capsInputSourceEnabled": true, "chromeTabEnabled": true, "leftControlAsCommandEnabled": true, "leftControlMAsReturnEnabled": true, "commandEToCommandMEnabled": true, "legacyTerminalCopyEnabled": true}, "pointerSpeedMultiplier": 9.9}"#
        let original = Data(json.utf8)
        try original.write(to: url)

        let result = configStore(in: directory).load()

        #expect(result.source == .currentFile)
        #expect(result.configuration.applications.ares == nil) // explicit nil preserved
        #expect(result.configuration.applications.codex == "com.example.codex") // trimmed
        #expect(result.configuration.applications.chrome == "com.google.Chrome")
        #expect(result.configuration.applications.lark == nil) // missing stays nil, not default
        #expect(result.configuration.pointerSpeedMultiplier == 2.0) // clamped
        let after = try Data(contentsOf: url)
        #expect(after == original)
    }
}

// MARK: - Save

struct FluxConfigurationStoreSaveTests {
    @Test func saveWritesSortedJSONWithTrailingNewline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = FluxConfigurationStore(fileURL: url)

        try store.save(.default)

        let data = try Data(contentsOf: url)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.hasSuffix("\n"))

        // The saved document is valid JSON once the trailing newline is removed.
        let parsed = try JSONSerialization.jsonObject(with: Data(data.dropLast()))
        #expect(parsed is [String: Any])

        // Frozen byte contract: sorted keys, deterministic order, newline.
        let expected = #"{"applications":{"ares":"com.ares.terminal","chrome":"com.google.Chrome","codex":"com.openai.codex","finder":"com.apple.finder","hermes":"com.nousresearch.hermes.setup","lark":"com.electron.lark","wechat":"com.tencent.xinWeChat","wps":"com.kingsoft.wpsoffice.mac"},"enabled":true,"mappings":{"capsEditingEnabled":true,"capsInputSourceEnabled":true,"capsTextNavigationEnabled":true,"chromeTabEnabled":true,"commandEToCommandMEnabled":true,"leftControlAsCommandEnabled":true,"leftControlMAsReturnEnabled":true,"legacyTerminalCopyEnabled":true},"pointerSpeedMultiplier":1,"schemaVersion":1}"# + "\n"
        #expect(json == expected)
    }

    @Test func saveCreatesParentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("config.json")

        try FluxConfigurationStore(fileURL: url).save(.default)

        #expect(FileManager.default.fileExists(atPath: url.path))
        var isDirectory: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory)
        #expect(dirExists)
        #expect(isDirectory.boolValue)
    }

    @Test func saveOverwritesRepeatedlyWithDeterministicBytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = FluxConfigurationStore(fileURL: url)

        try store.save(.default)
        let first = try Data(contentsOf: url)
        try store.save(.default)
        let second = try Data(contentsOf: url)
        #expect(first == second)

        try store.save(FluxConfiguration(enabled: false))
        let third = try Data(contentsOf: url)
        #expect(third != second)
        let decoded = try JSONDecoder().decode(FluxConfiguration.self, from: third)
        #expect(!decoded.enabled)
    }

    @Test func saveLeavesNoSiblingTempFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        try FluxConfigurationStore(fileURL: url).save(.default)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents == ["config.json"])
    }

    @Test func saveThenLoadRoundTrips() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = FluxConfigurationStore(fileURL: url)
        let config = FluxConfiguration(
            enabled: false,
            applications: .init(ares: nil, codex: "com.example.codex"),
            mappings: .init(chromeTabEnabled: false),
            pointerSpeedMultiplier: 1.5
        )

        try store.save(config)
        let result = store.load()

        #expect(result.source == .currentFile)
        #expect(result.configuration == config)
    }

    @Test func saveSanitizesBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = FluxConfigurationStore(fileURL: url)

        try store.save(
            FluxConfiguration(
                schemaVersion: 99,
                applications: .init(ares: "  com.example.ares  ", codex: ""),
                pointerSpeedMultiplier: 9.9
            )
        )

        let result = store.load()
        #expect(result.source == .currentFile)
        #expect(result.configuration.schemaVersion == 1)
        #expect(result.configuration.applications.ares == "com.example.ares")
        #expect(result.configuration.applications.codex == nil)
        #expect(result.configuration.pointerSpeedMultiplier == 2.0)
    }
}

// MARK: - File protection

struct FluxConfigurationStorePermissionTests {
    @Test func freshSaveApplies0700DirectoryAnd0600File() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("Flux", isDirectory: true)
            .appendingPathComponent("config.json")

        try FluxConfigurationStore(fileURL: url).save(.default)

        let directoryPerms = posixPermissions(of: url.deletingLastPathComponent().path)
        #expect(directoryPerms == 0o700)
        let filePerms = posixPermissions(of: url.path)
        #expect(filePerms == 0o600)
    }

    @Test func saveTightensPermissiveDirectoryTo0700() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fluxDirectory = directory.appendingPathComponent("Flux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fluxDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let url = fluxDirectory.appendingPathComponent("config.json")

        try FluxConfigurationStore(fileURL: url).save(.default)

        #expect(posixPermissions(of: fluxDirectory.path) == 0o700)
    }

    @Test func savePreservesStricterExistingFilePermissions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fluxDirectory = directory.appendingPathComponent("Flux", isDirectory: true)
        try FileManager.default.createDirectory(at: fluxDirectory, withIntermediateDirectories: true)
        let url = fluxDirectory.appendingPathComponent("config.json")
        try Data("stale".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        try FluxConfigurationStore(fileURL: url).save(.default)

        // 0400 is stricter than the 0600 target; it must not be weakened.
        #expect(posixPermissions(of: url.path) == 0o400)
    }

    @Test func saveRemovesExposedBitsFromNumericallyLowerFileMode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fluxDirectory = directory.appendingPathComponent("Flux", isDirectory: true)
        try FileManager.default.createDirectory(at: fluxDirectory, withIntermediateDirectories: true)
        let url = fluxDirectory.appendingPathComponent("config.json")
        try Data("stale".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o507], ofItemAtPath: url.path)

        try FluxConfigurationStore(fileURL: url).save(.default)

        #expect(posixPermissions(of: url.path) == 0o400)
    }

}
