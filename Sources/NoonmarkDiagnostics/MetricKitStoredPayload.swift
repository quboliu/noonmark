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
    let url: URL
    let isCurrentCorruption: Bool
}

struct MetricKitExportEnvelopeReadPolicy {
    let metricsDirectoryURL: URL
    let cutoff: Date
    let now: Date
    let maximumStoredEnvelopeBytes: Int64
    let maximumSanitizedJSONBytes: Int
}

enum MetricKitExportEnvelopeReader {
    static func read(
        from urls: [URL],
        policy: MetricKitExportEnvelopeReadPolicy
    ) -> MetricKitExportEnvelopeReadResult {
        var attachments: [DiagnosticMetricAttachment] = []
        var exclusions: [MetricKitExportEnvelopeExclusion] = []
        for url in urls {
            let read = readRegularFileWithoutFollowingLinks(
                at: url,
                metricsDirectoryURL: policy.metricsDirectoryURL,
                maximumByteCount: policy.maximumStoredEnvelopeBytes,
                now: policy.now
            )
            guard let data = read.data,
                  let stored = try? decoder.decode(
                      MetricKitStoredPayload.self,
                      from: data
                  )
            else {
                exclusions.append(
                    MetricKitExportEnvelopeExclusion(
                        url: url,
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
                        url: url,
                        isCurrentCorruption:
                        read.evidenceTimestamp >= policy.cutoff
                    )
                )
                continue
            }
            guard stored.receivedAt >= policy.cutoff else {
                exclusions.append(
                    MetricKitExportEnvelopeExclusion(
                        url: url,
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
        at url: URL,
        metricsDirectoryURL: URL,
        maximumByteCount: Int64,
        now: Date
    ) -> (data: Data?, evidenceTimestamp: Date) {
        let expectedDirectory = metricsDirectoryURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedDirectory else {
            return (nil, now)
        }

        let descriptor = Darwin.open(
            candidate.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return (nil, fallbackTimestamp(at: candidate, now: now))
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var information = stat()
        let readLimit = Int(
            min(maximumByteCount, Int64(Int.max - 1))
        )
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumByteCount,
              let data = try? handle.read(upToCount: readLimit + 1),
              data.count <= readLimit
        else {
            return (
                nil,
                timestamp(from: information.st_mtimespec, fallback: now)
            )
        }
        return (
            data,
            timestamp(from: information.st_mtimespec, fallback: now)
        )
    }

    private static func fallbackTimestamp(at url: URL, now: Date) -> Date {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return now }
        let modification = timestamp(
            from: information.st_mtimespec,
            fallback: .distantPast
        )
        if modification != .distantPast {
            return modification
        }
        return timestamp(
            from: information.st_birthtimespec,
            fallback: now
        )
    }

    private static func timestamp(
        from value: timespec,
        fallback: Date
    ) -> Date {
        let seconds = TimeInterval(value.tv_sec)
            + (TimeInterval(value.tv_nsec) / 1_000_000_000)
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    private static let decoder = JSONDecoder()
}

private enum MetricKitExportEnvelopeError: Error {
    case invalidKnownField
}
