@testable import NoonmarkSync
import XCTest

final class ICloudReplicationEvidenceTests: XCTestCase {
    func testOnlyCompleteExactPositiveAppleEvidenceConfirmsUpload() {
        let confirmed = evidence()
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(confirmed),
            .confirmed
        )

        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(exactURLObserved: false)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(exactDigestMatches: false)
            ),
            .blockedCorruption
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(exactDigestMatches: nil)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(isUbiquitous: nil)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(isUploading: nil)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(isUploaded: nil)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(hasUnresolvedConflicts: true)
            ),
            .blockedCorruption
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(isExcludedFromSync: true)
            ),
            .blockedUserAttention
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(uploadErrorCode: 4354)
            ),
            .blockedUserAttention
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(uploadErrorCode: 4355)
            ),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.classify(
                evidence(uploadErrorCode: 9999)
            ),
            .awaiting
        )

        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.aggregate([
                .confirmed,
                .awaiting,
                .blockedUserAttention,
                .blockedCorruption,
            ]),
            .blockedCorruption
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.aggregate([
                .confirmed,
                .awaiting,
                .blockedUserAttention,
            ]),
            .blockedUserAttention
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.aggregate([
                .confirmed,
                .awaiting,
            ]),
            .awaiting
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.aggregate([
                .confirmed,
                .confirmed,
            ]),
            .confirmed
        )
        XCTAssertEqual(
            ICloudReplicationEvidenceClassifier.aggregate([]),
            .awaiting
        )
    }

    private func evidence(
        exactURLObserved: Bool = true,
        exactDigestMatches: Bool? = true,
        isUbiquitous: Bool? = true,
        isExcludedFromSync: Bool? = false,
        hasUnresolvedConflicts: Bool? = false,
        isUploading: Bool? = false,
        isUploaded: Bool? = true,
        uploadErrorCode: Int? = nil
    ) -> ICloudReplicationObjectEvidence {
        ICloudReplicationObjectEvidence(
            exactURLObserved: exactURLObserved,
            exactDigestMatches: exactDigestMatches,
            isUbiquitous: isUbiquitous,
            isExcludedFromSync: isExcludedFromSync,
            hasUnresolvedConflicts: hasUnresolvedConflicts,
            isUploading: isUploading,
            isUploaded: isUploaded,
            uploadErrorCode: uploadErrorCode
        )
    }
}
