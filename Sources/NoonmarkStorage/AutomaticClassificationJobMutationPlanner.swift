import Foundation
@_spi(AutomaticClassificationJobAuthority) import NoonmarkCore

public enum AutomaticClassificationJobMutationPolicy: Equatable, Sendable {
    case reconcileExisting
    case taskDefinitionChanged(TaskChainID)
    case classificationCatalogChanged
    case newlyCreatedTaskChains
    case taskBecameIneligible(TaskChainID)
    case taskBecameEligible(TaskChainID)
    case userClassificationWins(TaskChainID)
}

public struct AutomaticClassificationJobMutationPlan: Equatable, Sendable {
    public let enqueues: [AutomaticClassificationJobEnqueue]
    public let mutations: [AutomaticClassificationJobMutation]

    public init(
        enqueues: [AutomaticClassificationJobEnqueue],
        mutations: [AutomaticClassificationJobMutation]
    ) {
        self.enqueues = enqueues
        self.mutations = mutations
    }

    public var isEmpty: Bool {
        enqueues.isEmpty && mutations.isEmpty
    }
}

public struct AutomaticClassificationJobMutationPlanner {
    private static let replaceableStates: Set<AutomaticClassificationJobState> = [
        .waitingForConfiguration,
        .ready,
        .running,
        .proposalReady,
        .failed
    ]

    private let jobIDGenerator: @Sendable () -> UUID

    public init() {
        jobIDGenerator = UUID.init
    }

    init(jobIDGenerator: @escaping @Sendable () -> UUID) {
        self.jobIDGenerator = jobIDGenerator
    }

    public func plan(
        policy: AutomaticClassificationJobMutationPolicy,
        candidate: NoonmarkEngine,
        originalSnapshot: NoonmarkSnapshot,
        existingJobs: [AutomaticClassificationJob],
        providerIsReady: Bool,
        operationalNow: Date
    ) throws -> AutomaticClassificationJobMutationPlan {
        guard operationalNow.timeIntervalSinceReferenceDate.isFinite else {
            throw NoonmarkError.invalidInput(
                "automatic classification operational time must be finite"
            )
        }

        if case let .taskBecameEligible(chainID) = policy {
            return try eligibilityRestorationPlan(
                chainID: chainID,
                candidate: candidate,
                existingJobs: existingJobs,
                providerIsReady: providerIsReady,
                operationalNow: operationalNow
            )
        }

        let latestJobs = latestReplaceableJobsByChain(existingJobs)
        let consideredChainIDs: [TaskChainID] = switch policy {
        case let .taskDefinitionChanged(chainID),
             let .taskBecameIneligible(chainID):
            latestJobs[chainID] == nil ? [] : [chainID]
        case .reconcileExisting, .classificationCatalogChanged,
             .newlyCreatedTaskChains, .taskBecameEligible,
             .userClassificationWins:
            latestJobs.keys.sorted(by: chainIDOrder)
        }
        let forcedUserChainID: TaskChainID? = if case let .userClassificationWins(
            chainID
        ) = policy {
            chainID
        } else {
            nil
        }
        let ineligibleChainID: TaskChainID? = if case let .taskBecameIneligible(
            chainID
        ) = policy {
            chainID
        } else {
            nil
        }
        var mutations: [AutomaticClassificationJobMutation] = []
        var forcedUserChainWasHandled = false
        var ineligibleChainWasHandled = false
        for chainID in consideredChainIDs {
            guard let source = latestJobs[chainID] else { continue }
            if chainID == ineligibleChainID {
                mutations.append(.invalidateChain(chainID))
                ineligibleChainWasHandled = true
                continue
            }
            if chainID == forcedUserChainID {
                mutations.append(.supersedeChain(chainID))
                forcedUserChainWasHandled = true
                continue
            }
            guard let nextGeneration = generation(after: source.generation) else {
                throw NoonmarkError.invalidTransition(
                    "automatic classification generation is exhausted"
                )
            }
            guard let context = try replacementContext(
                candidate: candidate,
                chainID: chainID,
                generation: nextGeneration
            ) else {
                mutations.append(.invalidateChain(chainID))
                continue
            }
            if context.authority.classificationFingerprint
                != source.classificationFingerprint
            {
                mutations.append(.supersedeChain(chainID))
                continue
            }
            guard context.authority.contentDigest != source.contentDigest
                || context.authority.catalogDigest != source.catalogDigest
            else { continue }
            mutations.append(
                .replace(
                    source.fence,
                    with: try makeEnqueue(
                        authority: context.authority,
                        providerIsReady: providerIsReady,
                        operationalNow: operationalNow
                    )
                )
            )
        }
        if let forcedUserChainID, forcedUserChainWasHandled == false {
            mutations.append(.supersedeChain(forcedUserChainID))
        }
        if let ineligibleChainID, ineligibleChainWasHandled == false {
            mutations.append(.invalidateChain(ineligibleChainID))
        }

        let enqueues: [AutomaticClassificationJobEnqueue]
        if case .newlyCreatedTaskChains = policy {
            let originalChainIDs = Set(originalSnapshot.chains.map(\.id))
            enqueues = try candidate.chains.keys
                .filter { originalChainIDs.contains($0) == false }
                .sorted(by: chainIDOrder)
                .map { chainID in
                    let context = try candidate.issueAutomaticClassificationContext(
                        for: chainID,
                        jobID: jobIDGenerator(),
                        generation: 1
                    )
                    return try makeEnqueue(
                        authority: context.authority,
                        providerIsReady: providerIsReady,
                        operationalNow: operationalNow
                    )
                }
        } else {
            enqueues = []
        }

        return AutomaticClassificationJobMutationPlan(
            enqueues: enqueues,
            mutations: mutations
        )
    }

    private func latestReplaceableJobsByChain(
        _ jobs: [AutomaticClassificationJob]
    ) -> [TaskChainID: AutomaticClassificationJob] {
        jobs.reduce(into: [:]) { result, job in
            guard Self.replaceableStates.contains(job.state) else { return }
            if let current = result[job.chainID], current.generation >= job.generation {
                return
            }
            result[job.chainID] = job
        }
    }

    private func eligibilityRestorationPlan(
        chainID: TaskChainID,
        candidate: NoonmarkEngine,
        existingJobs: [AutomaticClassificationJob],
        providerIsReady: Bool,
        operationalNow: Date
    ) throws -> AutomaticClassificationJobMutationPlan {
        guard let source = latestJob(
            for: chainID,
            among: existingJobs
        ),
            source.state == .superseded,
            source.errorCode == .taskBecameIneligible
        else {
            return AutomaticClassificationJobMutationPlan(
                enqueues: [],
                mutations: []
            )
        }
        guard let nextGeneration = generation(after: source.generation) else {
            throw NoonmarkError.invalidTransition(
                "automatic classification generation is exhausted"
            )
        }
        guard let context = try replacementContext(
            candidate: candidate,
            chainID: chainID,
            generation: nextGeneration
        ),
            context.authority.classificationFingerprint
            == source.classificationFingerprint
        else {
            return AutomaticClassificationJobMutationPlan(
                enqueues: [],
                mutations: []
            )
        }
        let replacement = try makeEnqueue(
            authority: context.authority,
            providerIsReady: providerIsReady,
            operationalNow: operationalNow
        )
        return AutomaticClassificationJobMutationPlan(
            enqueues: [],
            mutations: [
                .restoreEligibility(source.fence, with: replacement)
            ]
        )
    }

    private func latestJob(
        for chainID: TaskChainID,
        among jobs: [AutomaticClassificationJob]
    ) -> AutomaticClassificationJob? {
        jobs
            .filter { $0.chainID == chainID }
            .max { lhs, rhs in
                if lhs.generation == rhs.generation {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.generation < rhs.generation
            }
    }

    private func replacementContext(
        candidate: NoonmarkEngine,
        chainID: TaskChainID,
        generation: Int
    ) throws -> AutomaticTaskClassificationContext? {
        do {
            return try candidate.issueAutomaticClassificationContext(
                for: chainID,
                jobID: jobIDGenerator(),
                generation: generation
            )
        } catch NoonmarkError.notFound, NoonmarkError.chainAbandoned {
            return nil
        }
    }

    private func makeEnqueue(
        authority: AutomaticTaskClassificationAuthority,
        providerIsReady: Bool,
        operationalNow: Date
    ) throws -> AutomaticClassificationJobEnqueue {
        try AutomaticClassificationJobEnqueue(
            authority: authority,
            initialState: providerIsReady ? .ready : .waitingForConfiguration,
            dispatchAuthorization: providerIsReady
                ? .automatic
                : .pendingUserDecision,
            availableAt: operationalNow,
            createdAt: operationalNow
        )
    }

    private func generation(after current: Int) -> Int? {
        let (next, overflow) = current.addingReportingOverflow(1)
        return overflow ? nil : next
    }

    private func chainIDOrder(_ lhs: TaskChainID, _ rhs: TaskChainID) -> Bool {
        lhs.description < rhs.description
    }
}
