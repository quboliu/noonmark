import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct DataImportConfirmationSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    let preview: PreparedDataImport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.copy.importConfirmationTitle)
                        .font(.noonmarkSystem(size: 17, weight: .semibold))
                    Text(store.copy.importConfirmationMessage)
                        .font(.noonmarkSystem(size: 12))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(store.copy.importVerifiedPackage)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Text(preview.sourceURL.lastPathComponent)
                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                RailDivider()
                importMetric(store.copy.importDays, preview.summary.dayCount)
                importMetric(store.copy.importTasks, preview.summary.taskCount)
                importMetric(store.copy.importTraces, preview.summary.traceCount)
                importMetric(store.copy.importSubtasks, preview.summary.subtaskCount)
            }
            .padding(12)

            HStack {
                Spacer()
                Button(store.copy.cancel) {
                    store.cancelPreparedDataImport()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("data-import.cancel")
                Button(store.copy.confirmImport, role: .destructive) {
                    store.confirmPreparedDataImport()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("data-import.confirm")
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .background {
            AppE2EViewAnchor(identifier: "data-import.confirmation")
        }
    }

    private func importMetric(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.text2)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(Theme.text1)
        }
        .font(.noonmarkSystem(size: 12))
    }
}

struct FromPoolSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    @FocusState private var focusTarget: FocusTarget?

    private enum FocusTarget: Hashable {
        case task(TaskChainID)
        case cancel
    }

    private var tasks: [PoolTask] {
        store.engine.taskPool()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.copy.scheduleFromPoolSheetTitle)
                .font(.noonmarkSystem(size: 14, weight: .semibold))
            if store.selectedDate < store.today {
                Notice(text: store.copy.cannotSchedulePoolToPastNotice, tone: .locked)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(tasks, id: \.chain.id) { task in
                            Button {
                                store.schedulePoolTask(task.chain.id, date: store.selectedDate)
                                store.showingFromPoolPicker = false
                            } label: {
                                HStack {
                                    MarkdownInlineText(
                                        store.copy.displayTaskTitle(task.definition.title)
                                    )
                                    Spacer()
                                    Text(store.copy.schedule)
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusTarget, equals: .task(task.chain.id))
                        }
                    }
                }
                .frame(maxHeight: 320)

                if tasks.isEmpty {
                    EmptyState(kind: .taskPool, text: store.copy.emptyPool)
                }
            }
            Button(store.copy.cancel) { store.showingFromPoolPicker = false }
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.cancelAction)
                .focused($focusTarget, equals: .cancel)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            focusTarget = store.selectedDate >= store.today
                ? tasks.first.map { .task($0.chain.id) } ?? .cancel
                : .cancel
        }
        .accessibilityElement(children: .contain)
    }
}

struct ChangeTaskSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var titleFocusRequest = 0
    @State private var changeText = ""

    var oldTitle: String {
        guard let trace = store.selectedTrace else { return "" }
        return store.copy.displayTaskTitle(store.definition(for: trace)?.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.copy.changeTaskSheetTitle)
                .font(.noonmarkSystem(size: 14, weight: .semibold))
            Text(store.copy.changeTaskSheetNotice)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
            MarkdownText(oldTitle)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text3)
                .strikethrough()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            MarkdownEditor(
                text: $changeText,
                placeholder: store.copy.newTaskTitlePlaceholder,
                style: .title,
                onCommit: submit,
                nativeAccessibilityIdentifier: "change-task.title",
                focusRequest: titleFocusRequest
            )
                .frame(minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent))
            HStack {
                Spacer()
                Button(store.copy.cancel) { store.showingChangeDialog = false }
                    .keyboardShortcut(.cancelAction)
                Button(store.copy.confirmChange, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        changeText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            changeText = store.changeText
            titleFocusRequest &+= 1
        }
        .accessibilityElement(children: .contain)
    }

    private func submit() {
        store.changeText = changeText
        store.changeSelectedTrace()
    }
}
