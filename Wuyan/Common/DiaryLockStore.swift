import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 本机日记锁的凭据存储。只保存 PBKDF2 派生结果与随机盐，不保存明文密码。
enum DiaryLockStore {
    enum StoreError: LocalizedError {
        case passwordTooShort
        case invalidStoredCredential
        case keychainWriteFailed

        var errorDescription: String? {
            switch self {
            case .passwordTooShort: return "日记密码至少需要 8 个字符。"
            case .invalidStoredCredential: return "日记密码凭据损坏，请通过系统身份验证重设。"
            case .keychainWriteFailed: return "日记密码无法保存到钥匙串，设置未生效。"
            }
        }
    }

    enum CredentialState {
        case missing
        case available
        case unavailable
        case invalid
    }

    static var isEnabled: Bool {
        switch credentialState {
        case .available, .unavailable, .invalid: return true
        case .missing: return false
        }
    }

    static var credentialState: CredentialState {
        let hash = SecureSettings.loadKeychainOnly(SecureSettingKey.diaryPasswordHash)
        let salt = SecureSettings.loadKeychainOnly(SecureSettingKey.diaryPasswordSalt)
        switch (hash, salt) {
        case let (.value(hash), .value(salt)) where !hash.isEmpty && !salt.isEmpty:
            AppSettings.setDiaryPasswordEnabled(true)
            return .available
        case (.unavailable, _), (_, .unavailable):
            return AppSettings.diaryPasswordEnabled ? .unavailable : .missing
        case (.value, .value):
            return AppSettings.diaryPasswordEnabled ? .invalid : .missing
        default:
            return AppSettings.diaryPasswordEnabled ? .invalid : .missing
        }
    }

    static func save(password: String) throws {
        guard password.count >= 8 else { throw StoreError.passwordTooShort }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let digest = try digest(password: password, salt: salt)
        let oldHash = keychainValue(SecureSettingKey.diaryPasswordHash)
        let oldSalt = keychainValue(SecureSettingKey.diaryPasswordSalt)
        guard SecureSettings.save(digest, for: SecureSettingKey.diaryPasswordHash) else {
            throw StoreError.keychainWriteFailed
        }
        guard SecureSettings.save(salt.base64EncodedString(), for: SecureSettingKey.diaryPasswordSalt) else {
            // 恢复旧凭据，避免 hash 和 salt 不匹配导致日记被锁死。
            _ = SecureSettings.save(oldHash, for: SecureSettingKey.diaryPasswordHash)
            _ = SecureSettings.save(oldSalt, for: SecureSettingKey.diaryPasswordSalt)
            throw StoreError.keychainWriteFailed
        }
        AppSettings.setDiaryPasswordEnabled(true)
    }

    static func verify(password: String) -> Bool {
        guard case let .value(hash) = SecureSettings.loadKeychainOnly(SecureSettingKey.diaryPasswordHash),
              case let .value(saltValue) = SecureSettings.loadKeychainOnly(SecureSettingKey.diaryPasswordSalt) else { return false }
        guard
              let salt = Data(base64Encoded: saltValue),
              let calculated = try? digest(password: password, salt: salt)
        else { return false }
        guard let expected = Data(base64Encoded: hash), let actual = Data(base64Encoded: calculated), expected.count == actual.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expected, actual) { difference |= lhs ^ rhs }
        return difference == 0
    }

    static func remove() throws {
        let oldHash = keychainValue(SecureSettingKey.diaryPasswordHash)
        let oldSalt = keychainValue(SecureSettingKey.diaryPasswordSalt)
        guard SecureSettings.save("", for: SecureSettingKey.diaryPasswordHash) else {
            throw StoreError.keychainWriteFailed
        }
        guard SecureSettings.save("", for: SecureSettingKey.diaryPasswordSalt) else {
            _ = SecureSettings.save(oldHash, for: SecureSettingKey.diaryPasswordHash)
            _ = SecureSettings.save(oldSalt, for: SecureSettingKey.diaryPasswordSalt)
            throw StoreError.keychainWriteFailed
        }
        AppSettings.setDiaryPasswordEnabled(false)
    }

    static func authenticateForReset(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "重设晤言日记密码") { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    private static func digest(password: String, salt: Data) throws -> String {
        let key = try AESGCMCryptoBox().deriveKey(
            passphrase: password,
            salt: salt,
            params: KDFParams(salt: salt, iterations: 210_000)
        )
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private static func keychainValue(_ key: String) -> String {
        if case let .value(value) = SecureSettings.loadKeychainOnly(key) { return value }
        return ""
    }
}

struct DiaryUnlockThrottle {
    private(set) var failedAttempts = 0
    private(set) var lockedUntil: Date?

    func remainingSeconds(at date: Date = Date()) -> Int {
        guard let lockedUntil else { return 0 }
        return max(0, Int(ceil(lockedUntil.timeIntervalSince(date))))
    }

    mutating func recordFailure(at date: Date = Date()) -> Int {
        failedAttempts += 1
        let delay: TimeInterval
        switch failedAttempts {
        case ..<5: delay = 0
        case 5: delay = 30
        case 6: delay = 60
        default: delay = 300
        }
        lockedUntil = delay > 0 ? date.addingTimeInterval(delay) : nil
        return Int(delay)
    }

    mutating func reset() {
        failedAttempts = 0
        lockedUntil = nil
    }
}
