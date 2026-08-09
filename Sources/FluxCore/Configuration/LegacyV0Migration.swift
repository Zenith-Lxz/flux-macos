/// Decodable mirror of the exact legacy v0 JSON shape:
///
///     {
///       "version": 0,
///       "enabled": Bool?,
///       "apps": { "a": String?, "c": String?, "g": String?, "x": String?,
///                 "l": String?, "w": String?, "h": String?, "f": String? }?,
///       "pointerSpeed": Double?
///     }
///
/// Single-letter app keys map to the v1 semantic fields:
/// a=ares, c=codex, g=chrome, x=wechat, l=lark, w=wps, h=hermes, f=finder.
struct LegacyV0Configuration: Decodable, Sendable {
    let version: Int
    let enabled: Bool?
    let apps: [String: String?]?
    let pointerSpeed: Double?

    /// Deterministic migration: every missing, null, empty, or invalid v0
    /// value falls back to the current default; v0 has no mapping switches so
    /// all mapping defaults stay true.
    func migrated() -> FluxConfiguration {
        func appID(_ key: String, defaultID: String) -> String? {
            let raw = apps?[key] ?? nil
            return FluxConfiguration.sanitizedBundleID(raw) ?? defaultID
        }
        return FluxConfiguration(
            enabled: enabled ?? true,
            applications: FluxConfiguration.Applications(
                ares: appID("a", defaultID: AppBundleIdentifier.ares.rawValue),
                codex: appID("c", defaultID: AppBundleIdentifier.codex.rawValue),
                chrome: appID("g", defaultID: AppBundleIdentifier.chrome.rawValue),
                wechat: appID("x", defaultID: AppBundleIdentifier.wechat.rawValue),
                lark: appID("l", defaultID: AppBundleIdentifier.lark.rawValue),
                wps: appID("w", defaultID: AppBundleIdentifier.wps.rawValue),
                hermes: appID("h", defaultID: AppBundleIdentifier.hermes.rawValue),
                finder: appID("f", defaultID: AppBundleIdentifier.finder.rawValue)
            ),
            pointerSpeedMultiplier: FluxConfiguration.sanitizedPointerSpeed(pointerSpeed ?? 1.0)
        )
    }
}
