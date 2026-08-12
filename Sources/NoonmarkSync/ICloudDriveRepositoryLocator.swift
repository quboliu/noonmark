import Foundation

public enum ICloudDriveRepositoryLocationError:
    Error,
    Equatable,
    Sendable
{
    case accountUnavailable
    case driveUnavailable
}

extension ICloudDriveRepositoryLocationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            "iCloud Drive 不可用：请先登录 Apple Account 并开启 iCloud Drive。"
        case .driveUnavailable:
            "找不到 iCloud Drive 本机目录，请在系统设置中确认 iCloud Drive 已启用。"
        }
    }
}

public enum ICloudDriveRepositoryLocator {
    public static func defaultRootURL(
        repositoryName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let cloudDocsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true
            )
        return try resolvedRootURL(
            repositoryName: repositoryName,
            ubiquitousContainerURL: fileManager.url(
                forUbiquityContainerIdentifier: nil
            ),
            cloudDocsURL: cloudDocsURL,
            hasICloudAccount: fileManager.ubiquityIdentityToken != nil,
            cloudDocsExists: fileManager.fileExists(atPath: cloudDocsURL.path)
        )
    }

    static func resolvedRootURL(
        repositoryName: String,
        ubiquitousContainerURL: URL?,
        cloudDocsURL: URL,
        hasICloudAccount: Bool,
        cloudDocsExists: Bool
    ) throws -> URL {
        guard hasICloudAccount else {
            throw ICloudDriveRepositoryLocationError.accountUnavailable
        }
        if let ubiquitousContainerURL {
            return ubiquitousContainerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(repositoryName, isDirectory: true)
        }
        guard cloudDocsExists else {
            throw ICloudDriveRepositoryLocationError.driveUnavailable
        }
        return cloudDocsURL.appendingPathComponent(
            repositoryName,
            isDirectory: true
        )
    }
}
