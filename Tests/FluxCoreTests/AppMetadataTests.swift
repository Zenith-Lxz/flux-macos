import Testing
@testable import FluxCore

/// Contract tests for the frozen bundle metadata (design spec §7.1).
/// The packaging scripts and the generated Info.plist must match these values.
struct AppMetadataTests {
    @Test func currentBundleIdentifierIsFrozen() {
        #expect(AppMetadata.current.bundleIdentifier == "com.zenith.flux")
    }

    @Test func currentAppNameIsFlux() {
        #expect(AppMetadata.current.appName == "Flux")
    }

    @Test func currentExecutableNameMatchesPackageProduct() {
        #expect(AppMetadata.current.executableName == "FluxApp")
    }

    @Test func currentMinimumSystemVersionIsThirteen() {
        #expect(AppMetadata.current.minimumSystemVersion == "13.0")
    }

    @Test func currentVersionIsNonEmpty() {
        #expect(!AppMetadata.current.version.isEmpty)
    }

    @Test func currentHasNoEmptyFields() {
        let metadata = AppMetadata.current
        #expect(!metadata.bundleIdentifier.isEmpty)
        #expect(!metadata.appName.isEmpty)
        #expect(!metadata.executableName.isEmpty)
        #expect(!metadata.version.isEmpty)
        #expect(!metadata.minimumSystemVersion.isEmpty)
    }
}
