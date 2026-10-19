import AgentGridCore
import Foundation

/// 生成二维码/配对文本使用的 JSON。IP 会随网络切换而变化，因此需要可重复调用。
enum PairingText {
    static let port: UInt16 = 49_362

    static func make(serviceID: String, host: String, secret: Data) -> String {
        let payload = PairingPayload(
            serviceID: serviceID,
            host: host,
            port: port,
            secret: secret.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 让 WebSocket 服务线程读取最新配对文本（`/pairing` 本地 HTTP 入口）。
final class PairingTextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String) {
        self.text = text
    }

    var value: String {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
    }
}
