import NoonmarkZhulong
import SwiftUI

struct ZhulongWorkspaceRail: View {
    @ObservedObject var workspace: ZhulongWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.selectedSession == nil ? "工作空间" : "当前会话")
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)

            if let session = workspace.selectedSession {
                sessionInspector(session)
            } else {
                Text("从自然语言入口建立会话。Provider、记忆和 Todo 写入继续使用各自独立边界。")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            railDivider
            memoryInspector

            if let latest = workspace.records.last {
                railDivider
                DetailSection("最新事件") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latest.eyebrow)
                            .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                        Text(latest.title)
                            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(latest.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.noonmarkSystem(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("zhulong-workspace-rail")
    }

    private func sessionInspector(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection("本次意图") {
                Text(session.primaryIntent)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            railDivider
            DetailSection("数据范围") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            railDivider
            DetailSection("Provider 边界") {
                VStack(alignment: .leading, spacing: 4) {
                    if let identity = session.authorization?.providerIdentity {
                        Text(identity.providerID)
                            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(identity.location == .local ? "本地处理" : "远程发送 · \(identity.model)")
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(identity.location == .local ? Theme.ok : Theme.warn)
                    } else {
                        Text("尚未授权任何 Provider 配置身份")
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                    Text("切换身份或扩大范围时必须重新确认。")
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .accessibilityIdentifier("zhulong-memory-enabled")
                Text(
                    workspace.memoryLedger.isEnabled
                        ? "当前可用 \(workspace.memoryLedger.usableMemories.count) 项；候选未经确认不会进入后续会话。"
                        : "默认关闭。关闭时即使已有确认记录也不会进入提示上下文。"
                )
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        switch scope {
        case .currentDayTodo: "当前 Day Todo"
        case .taskPool: "任务池"
        case .unfinishedPool: "未完成池"
        case .completedPool: "已完成池"
        case .taskClassifications: "分组与标签"
        }
    }
}
