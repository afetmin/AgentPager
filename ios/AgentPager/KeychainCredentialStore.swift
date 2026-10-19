import AgentGridShared
import Foundation
import Security

/// 配对密钥、设备标识和控制序号都放进 Keychain：仅首次解锁后可读，且不迁移到其他设备。
struct KeychainCredentialStore: PhoneCredentialStore {
    private let service = "com.agentgrid.mobile"
    private let lock = NSLock()

    func load() throws -> PairingPayload? {
        guard let data = try read(account: "pairing") else { return nil }
        return try JSONDecoder().decode(PairingPayload.self, from: data)
    }

    func save(_ pairing: PairingPayload) throws {
        try write(account: "pairing", data: JSONEncoder().encode(pairing))
    }

    func clear() throws {
        // 控制序号绑定设备身份，解除配对后保留，避免新配对被 Bridge 判为重放。
        try delete(account: "pairing")
    }

    func reserveNextSequence() throws -> UInt64 {
        try lock.withLock {
            let previous = try read(account: "sequence").flatMap { data -> UInt64? in
                guard data.count == MemoryLayout<UInt64>.size else { return nil }
                return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            } ?? 0
            guard previous < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
            let next = previous + 1
            try write(account: "sequence", data: withUnsafeBytes(of: next) { Data($0) })
            return next
        }
    }

    /// 稳定的设备标识；卸载重装后 Keychain 项可能保留，也可能重新生成，两种情况序号都不会回退。
    func deviceID() throws -> String {
        if let data = try read(account: "device-id"), let value = String(data: data, encoding: .utf8) {
            return value
        }
        let value = UUID().uuidString.lowercased()
        try write(account: "device-id", data: Data(value.utf8))
        return value
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    private func write(account: String, data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }
        let addStatus = SecItemAdd(query(account: account).merging(attributes) { $1 } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
