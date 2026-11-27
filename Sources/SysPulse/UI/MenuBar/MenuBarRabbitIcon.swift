import AppKit

// MARK: - SysPulse 菜单栏图标

public enum MenuBarRabbitIcon {
    private static let rabbitBase64 = """
    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
    """

    public static let templateIcon: NSImage = {
        if let data = Data(base64Encoded: rabbitBase64), let img = NSImage(data: data) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }()
}
