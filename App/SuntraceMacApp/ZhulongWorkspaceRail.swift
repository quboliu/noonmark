import SuntraceZhulong
import SwiftUI

struct ZhulongWorkspaceRail: View {
    @ObservedObject var workspace: ZhulongWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(workspace.selectedSession == nil ? "工作空间" : "当前会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                StatusPill(
                    text: workspace.selectedSession == nil ? "本机" : workspace.selectedSessionStatus,
                    color: workspace.selectedSession?.workspaceStatus == .paused ? Theme.warn : Theme.accent
                )
            }

            if let session = workspace.selectedSession {
                sessionInspector(session)
            } else {
                Text("从自然语言入口建立会话。Provider、记忆和 Todo 写入继续使用各自独立边界。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            memoryInspector

            if let latest = workspace.records.last {
                DetailSection("最新事件") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latest.eyebrow)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                        Text(latest.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(latest.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("zhulong-workspace-rail")
    }

    private func sessionInspector(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSection("本次意图") {
                Text(session.primaryIntent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineSpacing(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }

            DetailSection("数据范围") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        HStack(spacing: 7) {
                            Image(systemName: "eye")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 14)
                            Text(scopeLabel(scope))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }

            DetailSection("Provider 边界") {
                VStack(alignment: .leading, spacing: 4) {
                    if let identity = session.authorization?.providerIdentity {
                        Text(identity.providerID)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(identity.location == .local ? "本地处理" : "远程发送 · \(identity.model)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(identity.location == .local ? Theme.ok : Theme.warn)
                    } else {
                        Text("尚未授权任何 Provider 配置身份")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                    Text("切换身份或扩大范围时必须重新确认。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
    }

    private var memoryInspector: some View {
        DetailSection("烛龙记忆") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "允许使用已确认记忆",
                    isOn: Binding(
                        get: { workspace.memoryLedger.isEnabled },
                        set: { enabled in workspace.setMemoryEnabled(enabled) }
                    )
                )
                .toggleStyle(.switch)
                .font(.system(size: 11.5, weight: .medium))
                .accessibilityIdentifier("zhulong-memory-enabled")
                Text(
                    workspace.memoryLedger.isEnabled
                        ? "当前可用 \(workspace.memoryLedger.usableMemories.count) 项；候选未经确认不会进入后续会话。"
                        : "默认关闭。关闭时即使已有确认记录也不会进入提示上下文。"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        switch scope {
        case .currentDayTodo: "当前 Day Todo"
        case .taskPool: "任务池"
        case .unfinishedPool: "未完成池"
        case .completedPool: "已完成池"
        case .taskClassifications: "分类与标签"
        }
    }
}
