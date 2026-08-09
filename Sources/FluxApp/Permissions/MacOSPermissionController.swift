// FluxApp.Permissions — macOS permission snapshot and user-invoked requests.
//
// Reads Accessibility trust and Input Monitoring access without prompting:
// construction and `snapshot()` never call the prompting APIs
// (design spec §8: first launch explains the purpose, then requests; the
// menu provides an explicit “打开权限设置” entry). Only the user-invoked
// `requestAndOpenRelevantSettings()` may prompt.
//
// Privacy boundary (design spec §8): this controller logs no paths, no user
// data, and no bundle metadata — only constant state and error codes.

import AppKit
import ApplicationServices
import IOKit

/// Input Monitoring access state as reported by `IOHIDCheckAccess`.
enum InputMonitoringAccess: Sendable, Equatable {
    case granted
    case denied
    case unknown
}

/// One read-only snapshot of the permissions Flux needs (design spec §8).
struct PermissionSnapshot: Sendable, Equatable {
    /// Whether the process is trusted for Accessibility.
    let accessibilityTrusted: Bool

    /// Whether Input Monitoring (listening to keyboard events) is granted.
    let inputMonitoring: InputMonitoringAccess

    /// True only when both permissions are granted.
    var isReady: Bool {
        accessibilityTrusted && inputMonitoring == .granted
    }
}

/// Reads permission state and performs user-invoked permission requests.
@MainActor
final class MacOSPermissionController {
    /// A fresh snapshot of both permissions. Never prompts.
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            inputMonitoring: Self.inputMonitoringAccess()
        )
    }

    /// The options key for `AXIsProcessTrustedWithOptions`. The SDK constant
    /// `kAXTrustedCheckOptionPrompt` is imported as mutable global state, so
    /// the documented string value is used directly to stay Swift 6
    /// concurrency-safe.
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    /// User-invoked: prompts for Accessibility trust and Input Monitoring,
    /// then opens only the first still-missing System Settings privacy pane
    /// (Accessibility first, then Input Monitoring; design spec §8).
    func requestAndOpenRelevantSettings() {
        let options = [
            Self.trustedCheckOptionPrompt: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let current = snapshot()
        if !current.accessibilityTrusted {
            openPrivacyPane(.accessibility)
        } else if current.inputMonitoring != .granted {
            openPrivacyPane(.inputMonitoring)
        }
    }

    // MARK: - Input Monitoring mapping

    private static func inputMonitoringAccess() -> InputMonitoringAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .unknown
        }
    }

    // MARK: - Settings panes

    private enum PrivacyPane {
        case accessibility
        case inputMonitoring
    }

    /// Opens one System Settings privacy pane. Only the first still-missing
    /// permission's pane is opened per request (design spec §8).
    private func openPrivacyPane(_ pane: PrivacyPane) {
        let url: URL
        switch pane {
        case .accessibility:
            url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
        case .inputMonitoring:
            url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )!
        }
        NSWorkspace.shared.open(url)
    }
}
