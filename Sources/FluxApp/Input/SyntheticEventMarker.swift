// FluxApp.Input — shared private synthetic-event marker.
//
// Every synthetic event Flux posts — keyboard strokes, remapped modifier
// flagsChanged events, pointer moves, and clicks — carries this single
// private value in its `eventSourceUserData` field so the session event tap
// can recognize Flux output and pass it through instead of reprocessing it
// (design spec §7, AGENTS.md engineering contract: synthetic events carry a
// private marker and are never reprocessed). The marker is module-internal:
// it never leaves the app target and never appears in FluxCore models.

/// The single shared `eventSourceUserData` marker for keyboard and pointer
/// output.
enum SyntheticEventMarker {
    static let value: Int64 = 0x4658_0001
}
