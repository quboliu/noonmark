import Foundation
import NoonmarkCore

/// Materializes one complete domain snapshot for a Replication V2 baseline.
///
/// Ordinary current-value entities remain individual records. Classification
/// is intentionally different: its current projection and immutable history
/// form one validated graph, so an existing graph is carried by a canonical
/// classification baseline instead of being omitted or reconstructed from a
/// mutation journal that may not exist after import or clean cut.
public struct ReplicationSnapshotRecordBuilder: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func records(
        from snapshot: NoonmarkSnapshot,
        modifiedBy deviceID: SyncDeviceID,
        createdAt: Date = Date(),
        classificationBaselineID: UUID = UUID()
    ) throws -> [SyncRecord] {
        var ordinarySnapshot = snapshot
        ordinarySnapshot.classifications = TaskClassificationState()
        var records = try mapper.records(
            from: ordinarySnapshot,
            modifiedBy: deviceID
        )
        if snapshot.classifications != TaskClassificationState() {
            let baseline = try ClassificationBaselineEnvelope(
                baselineID: classificationBaselineID,
                state: snapshot.classifications,
                createdAt: createdAt
            )
            records.append(
                try mapper.record(
                    for: baseline,
                    modifiedBy: deviceID
                )
            )
        }
        return records
    }
}
