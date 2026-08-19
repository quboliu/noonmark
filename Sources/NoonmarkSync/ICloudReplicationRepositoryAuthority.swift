import CryptoKit
import Foundation

enum ICloudReplicationRepositoryAuthorityError:
    Error,
    Equatable,
    Sendable
{
    case invalidRepositoryScope
    case invalidMarkerVersion
    case divergentMarkerVersion
    case unavailableMarkerVersion
}

enum ICloudReplicationRepositoryAuthority {
    private static let generationDomain =
        "app.noonmark.replication-v2.repository-generation\u{0}"

    static func generationID(for repositoryScope: String) throws -> UUID {
        try validateRepositoryScope(repositoryScope)
        var bytes = Array(
            SHA256.hash(
                data: Data((generationDomain + repositoryScope).utf8)
            ).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func generationID(
        for repositoryScope: String,
        preferred: UUID?
    ) throws -> UUID {
        try validateRepositoryScope(repositoryScope)
        if let preferred {
            return preferred
        }
        return try generationID(for: repositoryScope)
    }

    static func validateMarkerVersions(
        current: Data,
        conflicts: [Data]
    ) throws {
        try validateCanonicalMarker(current)
        for conflict in conflicts {
            try validateCanonicalMarker(conflict)
            guard conflict == current else {
                throw ICloudReplicationRepositoryAuthorityError
                    .divergentMarkerVersion
            }
        }
    }

    static func otherVersionData(at markerURL: URL) throws -> [Data] {
        let versions = (NSFileVersion.otherVersionsOfItem(at: markerURL) ?? [])
            + (NSFileVersion.unresolvedConflictVersionsOfItem(
                at: markerURL
            ) ?? [])
        return try versions.map { version in
            try coordinatedData(at: version.url)
        }
    }

    static func validateLocallyAvailableMarkerVersions(
        at markerURL: URL,
        expected descriptor: ReplicationRepositoryDescriptor
    ) throws {
        let current = try coordinatedData(at: markerURL)
        try validateMarkerVersions(
            current: current,
            conflicts: try otherVersionData(at: markerURL)
        )
        let expected = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        guard current == expected else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
    }

    static func validateMarkerVersions(
        at markerURL: URL,
        expected descriptor: ReplicationRepositoryDescriptor,
        nonlocalVersionData: @escaping @Sendable (URL) async throws -> [Data]
            = loadNonlocalVersionData
    ) async throws {
        let initialCurrent = try coordinatedData(at: markerURL)
        let initialLocalVersions = try otherVersionData(at: markerURL)
        let nonlocalVersions = try await nonlocalVersionData(markerURL)
        let finalCurrent = try coordinatedData(at: markerURL)
        let finalLocalVersions = try otherVersionData(at: markerURL)
        guard initialCurrent == finalCurrent else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
        try validateMarkerVersions(
            current: finalCurrent,
            conflicts: initialLocalVersions + nonlocalVersions
                + finalLocalVersions
        )
        let expected = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        guard finalCurrent == expected else {
            throw ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion
        }
    }
}

private extension ICloudReplicationRepositoryAuthority {
    static func validateRepositoryScope(_ repositoryScope: String) throws {
        guard repositoryScope.isEmpty == false,
              repositoryScope.utf8.contains(0) == false
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidRepositoryScope
        }
    }

    static func validateCanonicalMarker(_ data: Data) throws {
        let descriptor: ReplicationRepositoryDescriptor
        do {
            descriptor = try ReplicationPublicationBuilder
                .canonicalDecoder().decode(
                    ReplicationRepositoryDescriptor.self,
                    from: data
                )
        } catch {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidMarkerVersion
        }
        let canonical = try? ReplicationPublicationBuilder
            .canonicalEncoder().encode(descriptor)
        guard descriptor.formatVersion
            == FileReplicationRepositoryBootstrap.formatVersion,
            canonical == data
        else {
            throw ICloudReplicationRepositoryAuthorityError
                .invalidMarkerVersion
        }
    }

    static func coordinatedData(at url: URL) throws -> Data {
        var result: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }
        if coordinationError != nil || readError != nil {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        guard let result else {
            throw ICloudReplicationRepositoryAuthorityError
                .unavailableMarkerVersion
        }
        return result
    }

    static func loadNonlocalVersionData(at url: URL) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileVersion.getNonlocalVersionsOfItem(at: url) {
                versions,
                error in
                guard error == nil else {
                    continuation.resume(
                        throwing: ICloudReplicationRepositoryAuthorityError
                            .unavailableMarkerVersion
                    )
                    return
                }
                do {
                    continuation.resume(
                        returning: try (versions ?? []).map {
                            try coordinatedData(at: $0.url)
                        }
                    )
                } catch {
                    continuation.resume(
                        throwing: ICloudReplicationRepositoryAuthorityError
                            .unavailableMarkerVersion
                    )
                }
            }
        }
    }
}
