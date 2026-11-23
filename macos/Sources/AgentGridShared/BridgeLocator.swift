import Foundation
import Network

public enum BridgeServiceDiscovery {
    public static let serviceType = "_agentgrid._tcp"
    /// TXT 记录中携带配对 `serviceID` 的键。
    public static let serviceIDKey = "id"
}

public struct BridgeEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// 在局域网中重新找到已配对的 Bridge（Mac 的 IP 因 DHCP 或换网络而变化时使用）。
public protocol BridgeLocator: Sendable {
    func locate(serviceID: String) async -> BridgeEndpoint?
}

/// 在多个 Bonjour 结果里挑出配对的那台：只认 TXT 里 `id` 与配对 `serviceID` 完全一致的服务。
/// 不带 `id` 的旧版 Bridge 无法确认身份——局域网里别人的 Mac 与“自己的 Mac 暂时离线”看起来没有区别，
/// 宁可不重连，也不能把保存的地址改写成另一台机器。
enum BridgeServiceSelection {
    struct Candidate<Handle> {
        var serviceID: String?
        var handle: Handle
    }

    static func choose<Handle>(_ candidates: [Candidate<Handle>], serviceID: String) -> Handle? {
        candidates.first { $0.serviceID == serviceID }?.handle
    }
}

public final class BonjourBridgeLocator: BridgeLocator {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(4)) {
        self.timeout = timeout
    }

    public func locate(serviceID: String) async -> BridgeEndpoint? {
        let lookup = Lookup(serviceID: serviceID)
        return await withTaskCancellationHandler {
            await lookup.run(timeout: timeout)
        } onCancel: {
            lookup.cancel()
        }
    }
}

/// 一次浏览 + 解析。所有可变状态都只在自己的串行队列上访问。
private final class Lookup: @unchecked Sendable {
    private let serviceID: String
    private let queue = DispatchQueue(label: "com.agentgrid.bridge-locator")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<BridgeEndpoint?, Never>?
    private var resolving = false
    private var finished = false

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func run(timeout: Duration) async -> BridgeEndpoint? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                let browser = NWBrowser(
                    for: .bonjourWithTXTRecord(type: BridgeServiceDiscovery.serviceType, domain: nil),
                    using: .tcp
                )
                self.browser = browser
                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish(nil) }
                }
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    self?.consider(results)
                }
                browser.start(queue: self.queue)
                let nanoseconds = timeout.components.seconds * 1_000_000_000
                    + timeout.components.attoseconds / 1_000_000_000
                self.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                    self.finish(nil)
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(nil) }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        guard !finished, !resolving else { return }
        let candidates = results.map { result -> BridgeServiceSelection.Candidate<NWEndpoint> in
            var id: String?
            if case let .bonjour(record) = result.metadata {
                id = record[BridgeServiceDiscovery.serviceIDKey]
            }
            return .init(serviceID: id, handle: result.endpoint)
        }
        guard let endpoint = BridgeServiceSelection.choose(candidates, serviceID: serviceID) else { return }
        resolving = true
        resolve(endpoint)
    }

    /// 连一次服务端点，从已建立的路径里读出 IPv4 地址和端口。
    private func resolve(_ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    // IPv4Address 的描述可能带接口后缀（如 192.168.1.8%en0）。
                    let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    self.finish(BridgeEndpoint(host: address, port: Int(port.rawValue)))
                } else {
                    self.finish(nil)
                }
            case .failed, .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ endpoint: BridgeEndpoint?) {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        continuation?.resume(returning: endpoint)
        continuation = nil
    }
}
