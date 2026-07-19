import NoonmarkCore

/// A snapshot that has crossed Noonmark's complete domain-integrity seam.
///
/// Keeping the wrapped value private prevents sync callers from accidentally
/// rebuilding indexes from a raw snapshot whose identities or topology have
/// not been validated.
public struct ValidatedSyncSnapshot: Sendable {
    let snapshot: NoonmarkSnapshot

    public init(_ snapshot: NoonmarkSnapshot) throws {
        try snapshot.validateIntegrity()
        self.snapshot = snapshot
    }
}
