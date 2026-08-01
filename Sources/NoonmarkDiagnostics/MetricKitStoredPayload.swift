import Darwin
import Foundation

struct MetricKitStoredPayload: Codable {
    let receivedAt: Date
    let summary: MetricKitPayloadSummary
    let sanitizedJSON: Data?
    let redactionVersion: Int

    func defensivelySanitizedAttachment(
        maximumSanitizedJSONBytes: Int,
        now: Date
    ) throws -> DiagnosticMetricAttachment {
        let earliestAllowedDate = Date(timeIntervalSince1970: 0)
        guard redactionVersion == MetricKitJSONSanitizer.redactionVersion,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              summary.intervalStart.timeIntervalSinceReferenceDate.isFinite,
              summary.intervalEnd.timeIntervalSinceReferenceDate.isFinite,
              receivedAt >= earliestAllowedDate,
              summary.intervalStart >= earliestAllowedDate,
              summary.intervalEnd >= earliestAllowedDate,
              receivedAt <= now,
              summary.intervalStart <= summary.intervalEnd,
              summary.intervalEnd <= receivedAt,
              Self.validCount(summary.crashCount),
              Self.validCount(summary.hangCount),
              Self.validCount(summary.cpuExceptionCount),
              Self.validCount(summary.diskWriteExceptionCount),
              summary.rawJSONByteCount >= 0,
              summary.rawJSONByteCount <= Self.maximumReportedRawJSONBytes,
              sanitizedJSON?.count ?? 0 <= maximumSanitizedJSONBytes
        else {
            throw MetricKitExportEnvelopeError.invalidKnownField
        }
        let rebuiltSummary = MetricKitPayloadSummary(
            kind: summary.kind,
            intervalStart: summary.intervalStart,
            intervalEnd: summary.intervalEnd,
            crashCount: summary.crashCount,
            hangCount: summary.hangCount,
            cpuExceptionCount: summary.cpuExceptionCount,
            diskWriteExceptionCount: summary.diskWriteExceptionCount,
            rawJSONByteCount: summary.rawJSONByteCount
        )
        return try DiagnosticMetricAttachment(
            receivedAt: receivedAt,
            summary: rebuiltSummary,
            sanitizedJSON: sanitizedJSON.map(
                MetricKitJSONSanitizer.sanitize
            ),
            redactionVersion: MetricKitJSONSanitizer.redactionVersion
        )
    }

    private static func validCount(_ value: Int) -> Bool {
        value >= 0 && value <= maximumReportedCount
    }

    private static let maximumReportedCount = 1_000_000_000
    private static let maximumReportedRawJSONBytes = 1024 * 1024 * 1024
}

struct MetricKitExportEnvelopeReadResult {
    let attachments: [DiagnosticMetricAttachment]
    let exclusions: [MetricKitExportEnvelopeExclusion]
}

struct MetricKitExportEnvelopeExclusion {
    let entryName: String
    let isCurrentCorruption: Bool
}

struct MetricKitExportEnvelopeReadPolicy {
    let cutoff: Date
    let now: Date
    let maximumStoredEnvelopeBytes: Int64
    let maximumSanitizedJSONBytes: Int
}

enum MetricKitExportEnvelopeReader {
    static func read(
        from entryNames: [String],
        in directory: DiagnosticOwnedDirectory,
        policy: MetricKitExportEnvelopeReadPolicy,
        identityCapturedHook: (() throws -> Void)? = nil
    ) -> MetricKitExportEnvelopeReadResult {
        var attachments: [DiagnosticMetricAttachment] = []
        var exclusions: [MetricKitExportEnvelopeExclusion] = []
        for entryName in entryNames {
            let read = readRegularFileWithoutFollowingLinks(
                named: entryName,
                in: directory,
                maximumByteCount: policy.maximumStoredEnvelopeBytes,
                now: policy.now,
                identityCapturedHook: identityCapturedHook
            )
            guard let data = read.data,
                  let stored = try? decoder.decode(
                      MetricKitStoredPayload.self,
                      from: data
                  )
            else {
                exclusions.append(
                    MetricKitExportEnvelopeExclusion(
                        entryName: entryName,
                        isCurrentCorruption:
                        read.evidenceTimestamp >= policy.cutoff
                    )
                )
                continue
            }
            guard
                  let attachment = try? stored
                  .defensivelySanitizedAttachment(
                      maximumSanitizedJSONBytes:
                      policy.maximumSanitizedJSONBytes,
                      now: policy.now
                  )
            else {
                exclusions.append(
                    MetricKitExportEnvelopeExclusion(
                        entryName: entryName,
                        isCurrentCorruption:
                        read.evidenceTimestamp >= policy.cutoff
                    )
                )
                continue
            }
            guard stored.receivedAt >= policy.cutoff else {
                exclusions.append(
                    MetricKitExportEnvelopeExclusion(
                        entryName: entryName,
                        isCurrentCorruption: false
                    )
                )
                continue
            }
            attachments.append(attachment)
        }
        return MetricKitExportEnvelopeReadResult(
            attachments: attachments,
            exclusions: exclusions
        )
    }

    private static func readRegularFileWithoutFollowingLinks(
        named entryName: String,
        in directory: DiagnosticOwnedDirectory,
        maximumByteCount: Int64,
        now: Date,
        identityCapturedHook: (() throws -> Void)?
    ) -> (data: Data?, evidenceTimestamp: Date) {
        let information = try? directory.entryInformation(named: entryName)
        let evidenceTimestamp = information?.modificationDate ?? now
        guard isValidMetricEntryName(entryName),
              information?.isRegularFile == true
        else {
            return (nil, evidenceTimestamp)
        }
        do {
            try identityCapturedHook?()
        } catch {
            return (nil, evidenceTimestamp)
        }
        guard
              let data = try? directory.readFile(
                  named: entryName,
                  maximumByteCount: maximumByteCount
              )
        else {
            return (nil, evidenceTimestamp)
        }
        return (data, evidenceTimestamp)
    }

    private static func isValidMetricEntryName(_ name: String) -> Bool {
        let prefix = "metric-"
        let suffix = ".json"
        guard name.hasPrefix(prefix),
              name.hasSuffix(suffix),
              name.contains("/") == false,
              name.contains("\0") == false
        else { return false }
        let uuidStart = name.index(
            name.startIndex,
            offsetBy: prefix.count
        )
        let uuidEnd = name.index(
            name.endIndex,
            offsetBy: -suffix.count
        )
        return UUID(uuidString: String(name[uuidStart ..< uuidEnd])) != nil
    }

    private static let decoder = JSONDecoder()
}

private enum MetricKitExportEnvelopeError: Error {
    case invalidKnownField
}
