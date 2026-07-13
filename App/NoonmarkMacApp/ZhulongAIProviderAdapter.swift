import Foundation

enum ZhulongProviderUIError: LocalizedError {
    case providerDisabled
    case unsupportedProviderKind
    case missingSession
    case missingPlanningBrief
    case missingPlanningDelegation

    var errorDescription: String? {
        switch self {
        case .providerDisabled: "Provider 尚未启用"
        case .unsupportedProviderKind: "当前 Provider 类型尚未提供运行适配器"
        case .missingSession: "当前没有可运行的烛龙会话"
        case .missingPlanningBrief: "当前没有可委托的规划简报"
        case .missingPlanningDelegation: "当前规划简报尚未获得单次委托"
        }
    }
}
