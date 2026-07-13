import SuntraceAI
import SuntraceZhulong
import SwiftUI

struct ZhulongConvergedHome: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        ZhulongWorkspaceRoot(workspace: store.zhulongWorkspace)
    }
}

private struct ZhulongWorkspaceRoot: View {
    @ObservedObject var workspace: ZhulongWorkspaceStore

    var body: some View {
        if workspace.selectedSession != nil {
            ZhulongSessionStreamPage(workspace: workspace)
        } else {
            ZhulongWorkspaceHome(workspace: workspace)
        }
    }
}

private struct ZhulongWorkspaceHome: View {
    @EnvironmentObject private var store: SuntraceStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @FocusState private var intentIsFocused: Bool
    @State private var intent = ""

    private let examples = [
        ZhulongHomeExample(
            title: "规划一个还很模糊的大任务"
        ),
        ZhulongHomeExample(
            title: "结束今天并安排明天"
        ),
        ZhulongHomeExample(
            title: "梳理一条卡住的 Todo"
        )
    ]

    private var pendingCount: Int {
        workspace.sessions.filter { $0.workspaceStatus != .archived }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: store.copy.navZhulong,
                subtitle: "把模糊的事想清楚，把已经开始的事继续推进。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    intentComposer
                    pendingSection
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("zhulong-converged-home")
    }

    private var intentComposer: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text("你现在想推进什么？")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("先说结果，烛龙会在需要时再说明范围与授权。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 18)

                MarkdownEditor(
                    text: $intent,
                    placeholder: "说说你现在想推进什么……",
                    style: .compact,
                    showsSurface: false,
                    onCommit: startIntent
                )
                    .accessibilityIdentifier("zhulong-home-intent")

                Button(action: startIntent) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.text3 : Theme.accent)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .hoverSurface(
                    cornerRadius: 7,
                    idleFill: Theme.panel2,
                    hoverFill: Theme.accentSoft,
                    idleStroke: Theme.line,
                    hoverStroke: Theme.accent.opacity(0.28)
                )
                .accessibilityLabel("开始梳理")
                .accessibilityIdentifier("zhulong-home-submit")
            }
            .padding(.horizontal, 13)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(intentIsFocused ? Theme.accent.opacity(0.42) : Theme.line, lineWidth: intentIsFocused ? 1.4 : 1)
            )
            .shadow(color: Theme.text1.opacity(0.035), radius: 14, y: 7)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    ForEach(examples) { example in
                        exampleButton(example)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(examples) { example in
                        exampleButton(example)
                    }
                }
            }
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("待你决定", count: pendingCount)

            if pendingCount == 0 {
                Text("现在没有等待你处理的事项。可以从上方开始一件新工作。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(workspace.sessions.filter { $0.workspaceStatus != .archived }, id: \.id) { session in
                    ZhulongWorkspaceSessionRow(session: session) {
                        workspace.selectSession(session.id)
                    }
                    Divider().overlay(Theme.line)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Spacer()
            Text("\(count) 项")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func exampleButton(_ example: ZhulongHomeExample) -> some View {
        Button {
            intent = example.title
            intentIsFocused = true
        } label: {
            HStack(spacing: 4) {
                Text(example.title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .medium))
            }
            .font(.system(size: 10.8))
            .foregroundStyle(Theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("填入示例：\(example.title)")
    }

    private func startIntent() {
        let value = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }
        store.startZhulongWorkspaceSession(intent: value)
        intent = ""
        intentIsFocused = false
    }
}

private struct ZhulongWorkspaceSessionRow: View {
    let session: ZhulongSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.accentSoft)
                    Image(systemName: "text.append")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.primaryIntent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(sessionStatus)
                        .font(.system(size: 10.8))
                        .foregroundStyle(Theme.text2)
                    Text("下一步：继续同一条追加式会话流")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }

                Spacer(minLength: 10)
                Text("继续")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionStatus: String {
        if session.workspaceStatus == .paused { return "会话已暂停" }
        if session.workspaceStatus == .archived { return "会话已归档" }
        return switch session.phase {
        case .scopeReview: "等待你确认本次范围"
        case .readyForProvider: "范围已确认，可以继续推进"
        case .providerRunning: "Provider 正在运行"
        case .decisionGate: "等待你作出关键决定"
        case .draftReview: "草稿已形成，等待审查"
        }
    }
}

private struct ZhulongHomeExample: Identifiable {
    let title: String

    var id: String { title }
}

enum ZhulongHomeIntentResolver {
    static func task(for intent: String) -> ZhulongTask {
        let normalized = intent.lowercased()
        if containsAny(["收尾", "复盘", "回顾今天", "结束今天"], in: normalized) {
            return .dailyReview
        }
        if containsAny(["排期", "安排明天", "安排任务", "计划明天"], in: normalized) {
            return .scheduling
        }
        if containsAny(["标签", "分类", "归类"], in: normalized) {
            return .labelClassification
        }
        return .taskDecomposition
    }

    private static func containsAny(_ terms: [String], in value: String) -> Bool {
        terms.contains { value.contains($0) }
    }
}
