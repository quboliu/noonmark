import Foundation
import NoonmarkMacRuntime
import NoonmarkZhulong

enum ZhulongProviderDisclosureFormatter {
    static func endpoint(
        for identity: ZhulongProviderConfigurationIdentity
    ) -> String {
        guard let url = identity.baseURL,
              var components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )
        else {
            return identity.providerID
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? identity.providerID
    }

    static func disclosure(
        for identity: ZhulongProviderConfigurationIdentity,
        copy: ZhulongCopy
    ) -> String {
        guard identity.location == .remote else {
            return "\(copy.localProcessing) · \(identity.model)"
        }
        return copy.remoteRecipient(
            endpoint: endpoint(for: identity),
            model: identity.model
        )
    }
}
