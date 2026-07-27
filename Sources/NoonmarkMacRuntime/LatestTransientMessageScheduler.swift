import Foundation

typealias TransientMessageExpirySchedule = (
    Duration,
    @escaping @MainActor () -> Void
) -> Task<Void, Never>

@MainActor
public final class LatestTransientMessageScheduler {
    private var expiryTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private let scheduleExpiry: TransientMessageExpirySchedule

    public init() {
        scheduleExpiry = { duration, onExpire in
            Task { @MainActor in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                guard Task.isCancelled == false else {
                    return
                }
                onExpire()
            }
        }
    }

    init(
        scheduleExpiry: @escaping TransientMessageExpirySchedule
    ) {
        self.scheduleExpiry = scheduleExpiry
    }

    public func replace(
        after duration: Duration,
        onExpire: @escaping @MainActor () -> Void
    ) {
        expiryTask?.cancel()
        revision &+= 1
        let scheduledRevision = revision
        expiryTask = scheduleExpiry(duration) { [weak self] in
            guard let self,
                  revision == scheduledRevision
            else {
                return
            }
            onExpire()
        }
    }

    public func cancel() {
        revision &+= 1
        expiryTask?.cancel()
        expiryTask = nil
    }
}
