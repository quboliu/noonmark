import Foundation

@MainActor
public final class LatestTransientMessageScheduler {
    private var expiryTask: Task<Void, Never>?
    private var revision: UInt64 = 0

    public init() {}

    public func replace(
        after duration: Duration,
        onExpire: @escaping @MainActor () -> Void
    ) {
        expiryTask?.cancel()
        revision &+= 1
        let scheduledRevision = revision
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  let self,
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
