import Foundation
@testable import NoonmarkZhulong

func makeProviderIdentity(
    version: String = "v4",
    model: String? = nil,
    capabilities: Set<ZhulongProviderDataCapability> = [.structuredOutput, .taskContext]
) throws -> ZhulongProviderConfigurationIdentity {
    try ZhulongProviderConfigurationIdentity(
        providerID: "provider-\(version)",
        kind: .openAICompatible,
        baseURL: URL(string: "https://provider.example/\(version)")!,
        location: .remote,
        model: model ?? "model-\(version)",
        dataCapabilities: capabilities
    )
}
