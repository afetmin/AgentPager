import Foundation
import Security

public struct PairingPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var serviceID: String
    public var host: String
    public var port: UInt16
    public var secret: String

    public init(
        version: Int = 1,
        serviceID: String,
        host: String,
        port: UInt16,
        secret: String
    ) {
        self.version = version
        self.serviceID = serviceID
        self.host = host
        self.port = port
        self.secret = secret
    }
}

public enum PairingSecretStore {
    private static let service = "com.agentgrid.bridge"
    private static let account = "pairing-secret"

    public static func loadOrCreate() throws -> Data {
        if let value = load() {
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = Data(bytes)
        try save(data)
        return data
    }

    public static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    public static func save(_ data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public enum LocalNetworkAddress {
    public struct Candidate: Equatable, Sendable {
        public var interface: String
        public var address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    public static func preferredIPv4() -> String {
        select(from: candidates())
    }

    /// 选择写入二维码的地址：优先 en0/en1，其次其他以太网/Wi-Fi 接口（如有线网卡 en5），
    /// 忽略 VPN、虚拟网桥和链路本地地址；都没有时退回回环。
    public static func select(from candidates: [Candidate]) -> String {
        let usable = candidates.filter { candidate in
            !candidate.address.hasPrefix("169.254.") && !candidate.address.hasPrefix("127.")
        }
        func rank(_ candidate: Candidate) -> Int? {
            switch candidate.interface {
            case "en0": return 0
            case "en1": return 1
            default:
                return candidate.interface.hasPrefix("en") ? 2 : nil
            }
        }
        return usable
            .compactMap { candidate in rank(candidate).map { (candidate, $0) } }
            .min { $0.1 < $1.1 }?
            .0.address ?? "127.0.0.1"
    }

    private static func candidates() -> [Candidate] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var result: [Candidate] = []
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let end = host.firstIndex(of: 0) ?? host.endIndex
            result.append(Candidate(
                interface: String(cString: interface.ifa_name),
                address: String(decoding: host[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            ))
        }
        return result
    }
}
