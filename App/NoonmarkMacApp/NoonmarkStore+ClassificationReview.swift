import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore

extension NoonmarkStore {
    func isUnclassified(_ chainID: TaskChainID) -> Bool {
        guard let classification = currentClassification(for: chainID) else { return true }
        return classification.category == nil && classification.labels.isEmpty
    }

    func newTaskLabelSuggestions(for draft: String) -> [ClassificationCatalogItemProjection] {
        let selectedKeys = Set(parsedTaskDraft(draft).labelNames.map(ClassificationNameCanonicalizer.canonicalKey))
        return orderedActiveLabelSuggestions(
            query: lastHashQuery(in: draft),
            excludingCanonicalKeys: selectedKeys
        )
    }

    func shouldShowNewTaskLabelSuggestions(for draft: String) -> Bool {
        draft.contains("#")
            && lastHashQuery(in: draft) != nil
            && newTaskLabelSuggestions(for: draft).isEmpty == false
    }

    func completeLastHashToken(in draft: String, with labelName: String) -> String {
        guard let hashIndex = draft.lastIndex(of: "#") else {
            return "\(draft) #\(labelName)"
        }
        let prefix = draft[..<hashIndex]
        return "\(prefix)#\(labelName) "
    }

    private func orderedActiveLabelSuggestions(
        query: String?,
        excludingCanonicalKeys: Set<String>
    ) -> [ClassificationCatalogItemProjection] {
        let normalizedQuery = query?.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)) ?? ""
        return (classificationCatalog()?.labels ?? [])
            .filter { $0.lifecycle == .active }
            .filter { label in
                guard excludingCanonicalKeys.contains(ClassificationNameCanonicalizer.canonicalKey(label.name)) == false else {
                    return false
                }
                guard normalizedQuery.isEmpty == false else { return true }
                return label.name.localizedStandardContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.currentUsageCount != rhs.currentUsageCount {
                    return lhs.currentUsageCount > rhs.currentUsageCount
                }
                return ClassificationNameCanonicalizer.canonicalKey(lhs.name)
                    < ClassificationNameCanonicalizer.canonicalKey(rhs.name)
            }
    }

    private func taskLabelChoices(
        for names: [String],
        in candidate: NoonmarkEngine
    ) -> [TaskLabelChoice] {
        let catalog: ClassificationCatalogProjection? = if case let .catalog(projection) = try? candidate.classification(.catalog) {
            projection
        } else {
            nil
        }
        let activeLabels = (catalog?.labels ?? []).filter { $0.lifecycle == .active }
        var seenKeys: Set<String> = []
        return names.compactMap { rawName in
            let name = ClassificationNameCanonicalizer.displayName(
                rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            )
            let key = ClassificationNameCanonicalizer.canonicalKey(name)
            guard name.isEmpty == false, seenKeys.insert(key).inserted else { return nil }
            if let existing = activeLabels.first(where: {
                ClassificationNameCanonicalizer.canonicalKey($0.name) == key
            }), let id = UUID(uuidString: existing.id) {
                return .existing(TaskLabelID(id))
            }
            return .new(name: name, colorHex: "#0E9488")
        }
    }

    @discardableResult
    func applyTaskDraftLabels(
        to candidate: NoonmarkEngine,
        chainID: TaskChainID,
        labelNames: [String]
    ) throws -> Bool {
        let choices = taskLabelChoices(for: labelNames, in: candidate)
        guard choices.isEmpty == false else { return false }
        let interactionID = UUID()
        let mutationDate = candidate.nextClassificationMutationDate()
        let plan = try candidate.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: choices
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: mutationDate
        )
        _ = try candidate.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: interactionID
            ),
            now: mutationDate
        )
        return true
    }

    func updateReview(summary: String? = nil, reason: String? = nil, tomorrow: String? = nil) {
        let existing = engine.days[selectedDate]
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate in
                candidate.updateDailyReview(
                    date: selectedDate,
                    summary: summary ?? existing?.reviewSummary,
                    unfinishedReason: reason ?? existing?.reviewUnfinishedReason,
                    tomorrowNote: tomorrow ?? existing?.reviewTomorrowNote
                )
            }
            reviewAutosaveMessage = copy.reviewAutoSaved
        } catch {
            reviewAutosaveMessage = nil
            showOperationFailure(.dailyReview, error: error)
        }
    }

    func currentClassification(for chainID: TaskChainID) -> TaskClassificationProjection? {
        guard case let .task(projection) = try? engine.classification(.task(chainID)) else {
            return nil
        }
        return projection
    }

    func displayableClassification(
        for chainID: TaskChainID
    ) -> TaskClassificationDisplay? {
        guard let projection = currentClassification(for: chainID),
              projection.isEmpty == false
        else { return nil }
        return .current(projection)
    }

    func displayableClassification(
        for trace: DayTrace
    ) -> TaskClassificationDisplay? {
        if case let .history(projection) = try? engine.classification(.history(trace.id)) {
            if projection.category != nil || projection.labels.isEmpty == false {
                return .historical(projection)
            }
        }
        return displayableClassification(for: trace.chainID)
    }

    func classificationCatalog() -> ClassificationCatalogProjection? {
        guard case let .catalog(projection) = try? engine.classification(.catalog) else {
            return nil
        }
        return projection
    }

    @discardableResult
    func replaceTaskClassification(
        chainID: TaskChainID,
        category: TaskCategoryChoice?,
        labels: [TaskLabelChoice],
        interactionID: UUID = UUID()
    ) throws -> ClassificationReceipt {
        try commitEngineMutation(undoPolicy: .invalidate) { candidate in
            let mutationDate = candidate.nextClassificationMutationDate()
            let plan = try candidate.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: category,
                        labels: labels
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: mutationDate
            )
            return try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: mutationDate
            )
        }
    }

    @discardableResult
    func applyClassificationIntent(
        _ intent: ClassificationIntent,
        interactionID: UUID = UUID()
    ) throws -> ClassificationReceipt {
        try commitEngineMutation(undoPolicy: .invalidate) { candidate in
            let mutationDate = candidate.nextClassificationMutationDate()
            let plan = try candidate.prepareClassification(
                intent,
                source: .userDirect,
                interactionID: interactionID,
                now: mutationDate
            )
            guard plan.blockers.isEmpty else {
                throw NoonmarkError.invalidTransition(
                    "这个分组仍被任务或历史引用，不能废弃；可改为归档。"
                )
            }
            return try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: mutationDate
            )
        }
    }
}
