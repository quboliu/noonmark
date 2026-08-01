import Foundation
import NoonmarkDiagnostics

extension AppCopy {
    var versionInformationTitle: String {
        language == .chinese ? "版本信息" : "Version Information"
    }

    var copyVersionInformation: String {
        language == .chinese ? "复制版本信息" : "Copy Version Information"
    }

    var versionInformationCopied: String {
        language == .chinese ? "版本信息已复制" : "Version Information Copied"
    }

    var localDiagnosticsTitle: String {
        language == .chinese ? "本机诊断记录" : "Local diagnostics"
    }

    var localDiagnosticsPrivacySummary: String {
        switch language {
        case .chinese:
            "仅保留白名单化的阶段、计数、耗时和错误码；不含任务正文、凭证或同步路径，不会自动上传。最多占用 4 MiB，最长保留 7 天。"
        case .english:
            "Stores only allow-listed stages, counts, durations, and error codes—never task text, credentials, or sync paths. Nothing is uploaded automatically. Limited to 4 MiB and 7 days."
        }
    }

    var localDiagnosticsLoading: String {
        language == .chinese ? "正在读取诊断摘要…" : "Loading diagnostic summary…"
    }

    var localDiagnosticsSystemOnly: String {
        switch language {
        case .chinese:
            "文件型诊断记录当前不可用；App 已安全回退到 macOS 系统日志。"
        case .english:
            "File diagnostics are unavailable; the app has safely fallen back to macOS system logging."
        }
    }

    var exportDiagnostics: String {
        language == .chinese ? "导出诊断资料…" : "Export Diagnostics…"
    }

    var clearDiagnostics: String {
        language == .chinese ? "清除本机诊断记录" : "Clear Local Diagnostics"
    }

    var diagnosticsPreviewTitle: String {
        language == .chinese ? "导出前预览" : "Preview Before Export"
    }

    var diagnosticsPreviewContinue: String {
        language == .chinese ? "选择保存位置…" : "Choose Save Location…"
    }

    var diagnosticsExportPanelTitle: String {
        language == .chinese ? "导出晷迹诊断资料" : "Export Noonmark Diagnostics"
    }

    var diagnosticsExportSucceeded: String {
        language == .chinese ? "诊断资料已导出" : "Diagnostics exported"
    }

    var diagnosticsExportFailedTitle: String {
        language == .chinese ? "诊断资料未能导出" : "Diagnostics Could Not Be Exported"
    }

    var diagnosticsClearTitle: String {
        language == .chinese ? "清除本机诊断记录？" : "Clear Local Diagnostics?"
    }

    var diagnosticsClearMessage: String {
        switch language {
        case .chinese:
            "这只会删除晷迹管理的诊断记录，不会触碰任务、烛龙资料、同步仓库或数据包。"
        case .english:
            "This deletes only diagnostics managed by Noonmark. Tasks, Zhulong data, sync repositories, and data packages are untouched."
        }
    }

    var diagnosticsClearSucceeded: String {
        language == .chinese ? "本机诊断记录已清除" : "Local diagnostics cleared"
    }

    var diagnosticsClearFailedTitle: String {
        language == .chinese ? "诊断记录未能清除" : "Diagnostics Could Not Be Cleared"
    }

    func diagnosticIncidentLabel(_ incidentID: DiagnosticIncidentID) -> String {
        language == .chinese
            ? "诊断编号：\(incidentID.shortCode)"
            : "Diagnostic ID: \(incidentID.shortCode)"
    }

    func diagnosticHealthSummary(_ health: DiagnosticHealth) -> String {
        let allocated = ByteCountFormatter.string(
            fromByteCount: health.allocatedBytes,
            countStyle: .file
        )
        switch language {
        case .chinese:
            let sink = health.fileSinkDisabled
                ? "；文件写入已停用，当前仅保留 macOS 系统日志"
                : ""
            return "已保存 \(health.recordCount) 条证据，占用 \(allocated)；丢弃 \(health.droppedRecordCount) 条，损坏排除 \(health.corruptRecordCount) 条，超限排除 \(health.oversizedEventCount + health.oversizedMetricPayloadCount) 条\(sink)。"
        case .english:
            let sink = health.fileSinkDisabled
                ? "; file writes are disabled and only macOS system logging remains active"
                : ""
            return "\(health.recordCount) evidence records use \(allocated); \(health.droppedRecordCount) dropped, \(health.corruptRecordCount) corrupt, and \(health.oversizedEventCount + health.oversizedMetricPayloadCount) oversized records excluded\(sink)."
        }
    }

    func diagnosticExportPreview(_ preview: DiagnosticExportPreview) -> String {
        let allocated = ByteCountFormatter.string(
            fromByteCount: preview.allocatedBytes,
            countStyle: .file
        )
        let exportSize = ByteCountFormatter.string(
            fromByteCount: preview.estimatedExportBytes,
            countStyle: .file
        )
        let period = diagnosticPeriod(
            oldest: preview.oldestRecordAt,
            newest: preview.newestRecordAt
        )
        switch language {
        case .chinese:
            return "Schema v\(preview.schemaVersion)\n证据记录：\(preview.recordCount)\n进行中操作：\(preview.activeOperationCount)\n操作摘要：\(preview.operationCapsuleCount)\n系统诊断附件：\(preview.metricPayloadCount)\n本机占用：\(allocated)\n预计导出：\(exportSize)\n时间范围：\(period)\n\n资料不会自动发送；只有选择保存位置后才会建立导出文件。"
        case .english:
            return "Schema v\(preview.schemaVersion)\nEvidence records: \(preview.recordCount)\nActive operations: \(preview.activeOperationCount)\nOperation summaries: \(preview.operationCapsuleCount)\nSystem diagnostic attachments: \(preview.metricPayloadCount)\nLocal storage: \(allocated)\nEstimated export: \(exportSize)\nTime range: \(period)\n\nNothing is sent automatically. An export file is created only after you choose a save location."
        }
    }

    private func diagnosticPeriod(oldest: Date?, newest: Date?) -> String {
        guard let oldest, let newest else {
            return language == .chinese ? "暂无记录" : "No records"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: language == .chinese ? "zh_SG" : "en_SG"
        )
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
    }
}
