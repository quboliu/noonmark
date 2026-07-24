import Foundation

public enum ZhulongConversationCommand {
    public static func isCommit(_ content: String) -> Bool {
        let normalized = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "。！!，,；; "
                )
            )
        return [
            "提交",
            "提交吧",
            "确认提交",
            "按这个提交",
            "确认并提交",
            "commit",
            "commit it",
            "submit",
            "submit it",
            "confirm submit"
        ].contains(normalized)
    }
}
