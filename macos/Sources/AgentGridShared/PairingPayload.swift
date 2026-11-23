import Foundation

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
