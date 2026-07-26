import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime

extension NoonmarkStore {
    func isUnclassified(_ chainID: TaskChainID) -> Bool {
        guard let classification = currentClassification(for: chainID) else { return true }
        return classification.category == nil && classification.labels.isEmpty
    }

    func newTaskClassificationToken(
        for draft: String
    ) -> NewTaskClassificationToken? {
        NewTaskDraftParser.activeToken(in: draft)
    }

    func newTaskSlashCommandMatches(_ draft: String) -> Bool {
        guard let query = NewTaskDraftParser.activeCommandQuery(
            in: draft
        ) else {
            return false
        }
        let normalized = query.lowercased()
        return normalized.isEmpty
            || "重复".hasPrefix(normalized)
            || "repeat".hasPrefix(normalized)
    }

    func completeNewTaskSlashCommand() -> String {
        "\(copy.recurringSlashCommand) "
    }

    func newTaskClassificationSuggestions(
        for draft: String
    ) -> [ClassificationCatalogItemProjection] {
        guard let token = newTaskClassificationToken(for: draft) else { return [] }
        switch token.kind {
        case .label:
            let selectedKeys = Set(
                parsedTaskDraft(draft).labelNames.map(
                    ClassificationNameCanonicalizer.canonicalKey
                )
            )
            return orderedActiveLabelSuggestions(
                query: token.query,
                excludingCanonicalKeys: selectedKeys
            )
        case .category:
            return orderedActiveCategorySuggestions(query: token.query)
        }
    }

    func shouldShowNewTaskClassificationSuggestions(
        for draft: String
    ) -> Bool {
        newTaskClassificationToken(for: draft) != nil
            && newTaskClassificationSuggestions(for: draft).isEmpty == false
    }

    func completeNewTaskClassificationToken(
        in draft: String,
        with name: String
    ) -> String {
        NewTaskDraftParser.completingActiveToken(in: draft, with: name)
    }

    func newTaskDraftIssueMessage(for draft: String) -> String? {
        switch parsedTaskDraft(draft).issue {
        case .multipleCategories:
            copy.newTaskMultipleCategories
        case nil:
            nil
        }
    }

    private func orderedActiveCategorySuggestions(
        query: String
    ) -> [ClassificationCatalogItemProjection] {
        let normalizedQuery = query.trimmingCharacters(
            in: CharacterSet(charactersIn: "@").union(.whitespacesAndNewlines)
        )
        return (classificationCatalog()?.categories ?? [])
            .filter { $0.lifecycle == .active }
            .filter { category in
                normalizedQuery.isEmpty
                    || category.name.localizedStandardContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.currentUsageCount != rhs.currentUsageCount {
                    return lhs.currentUsageCount > rhs.currentUsageCount
                }
                return ClassificationNameCanonicalizer.canonicalKey(lhs.name)
                    < ClassificationNameCanonicalizer.canonicalKey(rhs.name)
            }
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

    private func taskCategoryChoice(
        for rawName: String?,
        in candidate: NoonmarkEngine
    ) -> TaskCategoryChoice? {
        guard let rawName else { return nil }
        let name = ClassificationNameCanonicalizer.displayName(
            rawName.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        )
        guard name.isEmpty == false else { return nil }
        let key = ClassificationNameCanonicalizer.canonicalKey(name)
        let catalog: ClassificationCatalogProjection? = if case let .catalog(projection) = try? candidate.classification(.catalog) {
            projection
        } else {
            nil
        }
        if let existing = catalog?.categories.first(where: {
            $0.lifecycle == .active
                && ClassificationNameCanonicalizer.canonicalKey($0.name) == key
        }), let id = UUID(uuidString: existing.id) {
            return .existing(TaskCategoryID(id))
        }
        return .new(name: name, colorHex: "#2A6FDB")
    }

    @discardableResult
    func applyTaskDraftClassification(
        to candidate: NoonmarkEngine,
        chainID: TaskChainID,
        categoryName: String?,
        labelNames: [String],
        now: Date
    ) throws -> Bool {
        let category = taskCategoryChoice(for: categoryName, in: candidate)
        let choices = taskLabelChoices(for: labelNames, in: candidate)
        guard category != nil || choices.isEmpty == false else { return false }
        let interactionID = UUID()
        let plan = try candidate.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: choices
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try candidate.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: interactionID
            ),
            now: now
        )
        return true
    }

    func updateReview(summary: String? = nil, reason: String? = nil, tomorrow: String? = nil) {
        let existing = engine.days[selectedDate]
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, moment in
                candidate.updateDailyReview(
                    date: selectedDate,
                    summary: summary ?? existing?.reviewSummary,
                    unfinishedReason: reason ?? existing?.reviewUnfinishedReason,
                    tomorrowNote: tomorrow ?? existing?.reviewTomorrowNote,
                    now: moment.instant
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
        try commitEngineMutation(
            undoPolicy: .invalidate,
            automaticClassificationPolicy: .userClassificationWins(chainID)
        ) { candidate, moment in
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
                now: moment.instant
            )
            return try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: moment.instant
            )
        }
    }

    func replaceTaskCycleClassification(
        seriesID: TaskCycleSeriesID,
        category: TaskCategoryChoice?,
        labels: [TaskLabelChoice],
        interactionID: UUID = UUID()
    ) throws {
        _ = try commitEngineMutation(
            undoPolicy: .invalidate,
            classificationCommitBoundaries: {
                $0.isEmpty ? nil : $0
            }
        ) { candidate, moment in
            let memberChainIDs = candidate
                .taskCycleEditableMemberChainIDs(
                    seriesID: seriesID,
                    today: moment.today
                )
            guard candidate.taskCycleSeries[seriesID]?
                .stoppedAfterDate == nil
            else {
                throw NoonmarkError.invalidTransition(
                    "stopped recurring tasks cannot change classification"
                )
            }
            let fallbackChainIDs = candidate.chains.values
                .filter {
                    $0.cycleMembership?.seriesID == seriesID
                }
                .sorted {
                    guard let lhs = $0.cycleMembership,
                          let rhs = $1.cycleMembership
                    else {
                        return $0.id.description < $1.id.description
                    }
                    return lhs.occurrenceDate < rhs.occurrenceDate
                }
                .map(\.id)
            guard let anchorChainID =
                memberChainIDs.first ?? fallbackChainIDs.last
            else {
                throw NoonmarkError.notFound("task cycle occurrence")
            }
            let plan = try candidate.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: anchorChainID,
                        category: category,
                        labels: labels
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: moment.instant
            )
            _ = try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: moment.instant
            )
            var boundaries = [candidate.snapshot()]
            guard let classification = candidate.snapshot().classifications
                .currentByChainID[anchorChainID]
            else {
                throw NoonmarkError.invalidInput(
                    "recurring task classification did not commit"
                )
            }
            try candidate.setTaskCycleTemplateClassification(
                seriesID: seriesID,
                categoryID: classification.categoryID,
                labelIDs: classification.labelIDs,
                now: moment.instant
            )
            for chainID in memberChainIDs where chainID != anchorChainID {
                if try candidate.inheritCurrentClassification(
                    from: anchorChainID,
                    to: chainID,
                    now: moment.instant
                ) {
                    boundaries.append(candidate.snapshot())
                }
            }
            return boundaries
        }
    }

    @discardableResult
    func applyClassificationIntent(
        _ intent: ClassificationIntent,
        interactionID: UUID = UUID()
    ) throws -> ClassificationReceipt {
        let receipt = try commitEngineMutation(
            undoPolicy: .invalidate,
            automaticClassificationPolicy: .classificationCatalogChanged
        ) { candidate, moment in
            let plan = try candidate.prepareClassification(
                intent,
                source: .userDirect,
                interactionID: interactionID,
                now: moment.instant
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
                now: moment.instant
            )
        }
        automaticClassificationJobsDidChange()
        return receipt
    }

    @discardableResult
    func deleteTaskCategoryFromToday(
        _ categoryID: TaskCategoryID,
        interactionID: UUID = UUID()
    ) throws -> TaskCategoryDeletionOutcome {
        let sequence = try commitEngineMutation(
            undoPolicy: .invalidate,
            automaticClassificationPolicy: .classificationCatalogChanged,
            classificationCommitBoundaries: {
                $0.commitBoundaries
            }
        ) { candidate, moment in
            try candidate
                .deleteTaskCategoryFromTodayRecordingCommitBoundaries(
                    categoryID,
                    today: moment.today,
                    interactionID: interactionID,
                    decisionID: interactionID,
                    now: moment.instant
                )
        }
        automaticClassificationJobsDidChange()
        showToast(copy.taskCategoryDeletedFromToday)
        return sequence.outcome
    }
}
