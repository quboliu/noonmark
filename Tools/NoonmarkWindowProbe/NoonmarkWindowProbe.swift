import CoreGraphics
import Darwin
import Foundation
import NoonmarkMacE2ESupport

@main
enum NoonmarkWindowProbe {
    static func main() {
        do {
            let windowNumber = try parseWindowNumber(
                Array(CommandLine.arguments.dropFirst())
            )
            let snapshot = try ScopedWindowServerLookup.exactSnapshot(
                windowNumber: windowNumber
            )
            var output = try ScopedWindowServerSnapshotEnvelope(
                snapshot: snapshot
            ).canonicalJSONData()
            output.append(0x0A)
            FileHandle.standardOutput.write(output)
        } catch let failure as ScopedWindowServerLookupFailure {
            fail(reason(for: failure))
        } catch let failure as ScopedWindowServerSnapshotEncodingFailure {
            switch failure {
            case .invalidMaximumByteCount:
                fail("output-bound-invalid")
            case .exceedsMaximumByteCount:
                fail("snapshot-output-oversized")
            }
        } catch let failure as ProbeFailure {
            fail(failure.rawValue)
        } catch {
            fail("output-encoding-failed")
        }
    }

    private enum ProbeFailure: String, Error {
        case invalidInput = "invalid-input"
    }

    private static func parseWindowNumber(
        _ arguments: [String]
    ) throws -> CGWindowID {
        guard arguments.count == 2,
              arguments[0] == "--window-number",
              arguments[1].first != "0",
              arguments[1].utf8.allSatisfy({ 48 ... 57 ~= $0 }),
              let windowNumber = CGWindowID(arguments[1]),
              windowNumber > 0
        else {
            throw ProbeFailure.invalidInput
        }
        return windowNumber
    }

    private static func reason(
        for failure: ScopedWindowServerLookupFailure
    ) -> String {
        switch failure {
        case .invalidWindowNumber:
            "invalid-input"
        case .queryUnavailable:
            "query-unavailable"
        case let .unexpectedRecordCount(count):
            "query-count-\(count)"
        case .windowNumberMismatch:
            "window-number-mismatch"
        }
    }

    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("\(reason)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
