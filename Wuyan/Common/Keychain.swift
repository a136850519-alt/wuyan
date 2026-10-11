import Foundation
import Security

struct Keychain {
    static let service = "com.wuyan.app"
    static let testService = "com.wuyan.tests"
    private let serviceName: String
    private let readOverride: ((String) -> ReadResult)?

    init(service: String = Keychain.service, readOverride: ((String) -> ReadResult)? = nil) {
        self.serviceName = service
        self.readOverride = readOverride
    }

    enum ReadResult {
        case value(String)
        case missing
        case unavailable(OSStatus)
    }

    func readString(for account: String) -> ReadResult {
        if let readOverride { return readOverride(account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .unavailable(status)
        }
        return .value(value)
    }

    func string(for account: String) -> String? {
        if case let .value(value) = readString(for: account) { return value }
        return nil
    }

    /// R0-6: setString 现在返回是否成功，避免静默丢失凭据。
    @discardableResult
    func setString(_ value: String?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: serviceName
        ]
        if let value {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess {
                let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                return updateStatus == errSecSuccess
            } else {
                var item = query
                attributes.forEach { item[$0.key] = $0.value }
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                return addStatus == errSecSuccess
            }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }
}
