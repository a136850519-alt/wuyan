import CommonCrypto
import CryptoKit
import Foundation
import Security

struct KDFParams: Codable, Equatable {
    var salt: Data
    var iterations: Int = 210_000
    var kdfAlgorithm: String = "PBKDF2-HMAC-SHA256"
}

enum CryptoError: LocalizedError {
    case invalidKDFParameter(String)
    case keyDerivationFailed(Int32)
    case randomGenerationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .invalidKDFParameter(message): return "加密参数无效：\(message)"
        case let .keyDerivationFailed(status): return "密钥派生失败（CommonCrypto 状态码 \(status)）。"
        case let .randomGenerationFailed(status): return "安全随机数生成失败（状态码 \(status)）。"
        }
    }
}

protocol CryptoBox {
    func deriveKey(passphrase: String, salt: Data, params: KDFParams) throws -> SymmetricKey
    func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data
    func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data
}

struct AESGCMCryptoBox: CryptoBox {
    /// 使用 CommonCrypto 的 CCKeyDerivationPBKDF 进行密钥派生，
    /// 比纯 Swift 循环快数倍，且避免阻塞主线程。
    func deriveKey(passphrase: String, salt: Data, params: KDFParams) throws -> SymmetricKey {
        guard !passphrase.isEmpty else {
            throw CryptoError.invalidKDFParameter("口令不能为空")
        }
        guard salt.count >= 8, salt.count <= 64 else {
            throw CryptoError.invalidKDFParameter("盐长度必须在 8 到 64 字节之间")
        }
        guard params.salt == salt else {
            throw CryptoError.invalidKDFParameter("KDF 参数中的盐与实际盐不一致")
        }
        guard params.kdfAlgorithm == "PBKDF2-HMAC-SHA256" else {
            throw CryptoError.invalidKDFParameter("不支持的 KDF 算法：\(params.kdfAlgorithm)")
        }
        // 允许测试和历史 fixture 使用较低迭代次数，但拒绝 0、负数和会造成资源耗尽的异常值。
        guard (1...5_000_000).contains(params.iterations) else {
            throw CryptoError.invalidKDFParameter("迭代次数必须在 1 到 5000000 之间")
        }
        let iterations = UInt32(params.iterations)
        var derivedKey = Data(count: 32)  // dkLen = 32 bytes = 1 个 SHA256 块

        let status: Int32 = derivedKey.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase,
                    passphrase.utf8.count,
                    saltPtr.baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedPtr.baseAddress,
                    32
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw CryptoError.keyDerivationFailed(status)
        }

        return SymmetricKey(data: derivedKey)
    }

    func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { return Data() }
        return combined
    }

    func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }
}

/// S03/UI-01（已确认：数据密钥方案）。
/// 远端对象统一由随机 32 字节数据密钥（DEK）加密；口令经 PBKDF2 派生 KEK，
/// 只用于包装/解包 DEK。DEK 的包装结果随 manifest 密钥头存放：
/// - 换口令 = 用旧口令解包 DEK 验证身份 → 新盐重新包装 → 只重写索引头（数据不动，秒级完成）；
/// - 关闭加密 = 全量迁移为明文（独立流程）；
/// - 旧版（v1/v2，逐对象口令派生）对象仍可读取，读取后自动标记升级重传。
final class SyncCrypto: @unchecked Sendable {
    let box = AESGCMCryptoBox()
    private let passphrase: String
    private let persistenceKey: String?
    private let lock = NSLock()

    private var header: CryptoManifestHeader?
    private var dek: SymmetricKey?
    /// 旧版兼容：按盐缓存的口令派生密钥（也用于解包 KEK）
    private var legacyKeyCache: [String: SymmetricKey] = [:]

    init(passphrase: String, persistenceKey: String? = nil) {
        self.passphrase = passphrase
        self.persistenceKey = persistenceKey
    }

    /// 兼容旧签名（测试/既有调用）：固定盐预热旧版密钥缓存。DEK 协议的盐来自索引头。
    convenience init(passphrase: String, salt: Data, persistenceKey: String? = nil) throws {
        self.init(passphrase: passphrase, persistenceKey: persistenceKey)
        let params = KDFParams(salt: salt)
        _ = try legacyKey(saltBase64: salt.base64EncodedString(), iterations: params.iterations)
    }

    // MARK: - 旧版（v1/v2）逐对象口令派生

    /// 按盐派生并缓存口令密钥（PBKDF2 每个盐只算一次）。同时用于解包 DEK 的 KEK。
    func key(forSaltBase64 saltB64: String, iterations: Int) throws -> SymmetricKey {
        return try Self.locked(lock) {
            let cacheKey = "\(saltB64)|\(iterations)|PBKDF2-HMAC-SHA256"
            if let cached = legacyKeyCache[cacheKey] { return cached }
            guard let salt = Data(base64Encoded: saltB64) else {
                throw RemoteStorageError.missingConfiguration("加密盐无效")
            }
            let derived = try box.deriveKey(passphrase: passphrase, salt: salt, params: KDFParams(salt: salt, iterations: iterations))
            legacyKeyCache[cacheKey] = derived
            return derived
        }
    }

    private func legacyKey(saltBase64: String, iterations: Int) throws -> SymmetricKey {
        try key(forSaltBase64: saltBase64, iterations: iterations)
    }

    // MARK: - DEK 协议

    /// 当前密钥头（已解锁或已生成）；nil 表示尚未初始化。
    var currentHeader: CryptoManifestHeader? {
        Self.locked(lock) { header }
    }

    var currentKeyId: String? {
        Self.locked(lock) { header?.keyId }
    }

    /// 无头时生成全新 DEK + 密钥头（首次启用加密且远端还没有加密索引时调用）。
    func makeFreshHeaderIfAbsent() throws -> CryptoManifestHeader {
        if currentHeader == nil, let persistenceKey,
           let data = Self.pendingHeaderDefaults.data(forKey: persistenceKey),
           let saved = try? JSONDecoder.wuyan.decode(CryptoManifestHeader.self, from: data) {
            do {
                try unlock(with: saved)
                return saved
            } catch {
                Self.pendingHeaderDefaults.removeObject(forKey: persistenceKey)
            }
        }
        return try Self.locked(lock) {
            if let header { return header }
            let salt = try Self.randomSalt()
            let params = KDFParams(salt: salt)
            let newDek = SymmetricKey(size: .bits256)
            let kek = try box.deriveKey(passphrase: passphrase, salt: salt, params: params)
            let wrapped = try box.seal(newDek.withUnsafeBytes { Data($0) }, key: kek)
            let newHeader = CryptoManifestHeader(
                saltBase64: salt.base64EncodedString(),
                iterations: params.iterations,
                keyId: Self.keyId(of: newDek),
                wrappedDekBase64: wrapped.base64EncodedString()
            )
            header = newHeader
            dek = newDek
            persist(newHeader)
            return newHeader
        }
    }

    /// 用 manifest 携带的密钥头解锁 DEK。口令错误会在此抛错——这也是换口令/开启加密时的验证手段。
    func unlock(with manifestHeader: CryptoManifestHeader) throws {
        guard manifestHeader.algorithm == "AES-GCM",
              manifestHeader.kdf == "PBKDF2-HMAC-SHA256" else {
            throw CryptoError.invalidKDFParameter("远端索引使用了不支持的加密算法或 KDF")
        }
        guard let wrappedB64 = manifestHeader.wrappedDekBase64,
              let wrapped = Data(base64Encoded: wrappedB64) else {
            throw SyncError.decryptFailed(reason: "加密索引缺少数据密钥头，可能是旧版格式：请先同步一次完成升级")
        }
        let kek = try key(forSaltBase64: manifestHeader.saltBase64, iterations: manifestHeader.iterations)
        let dekData: Data
        do {
            dekData = try box.open(wrapped, key: kek)
        } catch {
            throw SyncError.decryptFailed(reason: "口令可能不正确（无法解包数据密钥）")
        }
        guard dekData.count == 32 else {
            throw SyncError.decryptFailed(reason: "远端数据密钥长度无效")
        }
        let unlocked = SymmetricKey(data: dekData)
        if let expectedId = manifestHeader.keyId, expectedId != Self.keyId(of: unlocked) {
            throw SyncError.decryptFailed(reason: "数据密钥校验失败：索引可能被篡改或口令不一致")
        }
        Self.locked(lock) {
            header = manifestHeader
            dek = unlocked
        }
        persist(manifestHeader)
    }

    /// 取当前已解锁的 DEK；keyId 不匹配（远端换过密钥头而本机未重新同步）时报错。
    func dekForKeyId(_ keyId: String?) throws -> SymmetricKey {
        try Self.locked(lock) {
            guard let dek else {
                throw SyncError.decryptFailed(reason: "加密密钥尚未解锁：请先完成一次同步以读取远端索引")
            }
            if let keyId, keyId != Self.keyId(of: dek) {
                throw SyncError.decryptFailed(reason: "远端对象使用了未知的数据密钥：请先同步以更新密钥头")
            }
            return dek
        }
    }

    func sealWithDEK(_ plaintext: Data) throws -> Data {
        let dek = try dekForKeyId(currentKeyId)
        return try box.seal(plaintext, key: dek)
    }

    /// S03/UI-01：换口令——用旧口令解包 DEK（错误口令在此抛错），再用新口令重新包装。
    /// 返回新的密钥头；数据对象与索引密文完全不动。
    func rewrappedHeader(with newPassphrase: String, from oldHeader: CryptoManifestHeader) throws -> CryptoManifestHeader {
        guard oldHeader.algorithm == "AES-GCM",
              oldHeader.kdf == "PBKDF2-HMAC-SHA256" else {
            throw CryptoError.invalidKDFParameter("远端索引使用了不支持的加密算法或 KDF")
        }
        guard !newPassphrase.isEmpty else {
            throw CryptoError.invalidKDFParameter("新口令不能为空")
        }
        guard let wrappedB64 = oldHeader.wrappedDekBase64,
              let wrapped = Data(base64Encoded: wrappedB64) else {
            throw SyncError.decryptFailed(reason: "加密索引缺少数据密钥头，无法更换口令")
        }
        let oldKek = try key(forSaltBase64: oldHeader.saltBase64, iterations: oldHeader.iterations)
        let dekData: Data
        do {
            dekData = try box.open(wrapped, key: oldKek)
        } catch {
            throw SyncError.decryptFailed(reason: "当前口令不正确（无法解包数据密钥）")
        }
        guard dekData.count == 32 else {
            throw SyncError.decryptFailed(reason: "远端数据密钥长度无效")
        }
        let newSalt = try Self.randomSalt()
        let newParams = KDFParams(salt: newSalt)
        let newKek = try box.deriveKey(passphrase: newPassphrase, salt: newSalt, params: newParams)
        let newWrapped = try box.seal(dekData, key: newKek)
        return CryptoManifestHeader(
            saltBase64: newSalt.base64EncodedString(),
            iterations: newParams.iterations,
            keyId: Self.keyId(of: SymmetricKey(data: dekData)),
            wrappedDekBase64: newWrapped.base64EncodedString()
        )
    }

    private static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CryptoError.randomGenerationFailed(Int32(status))
        }
        return Data(bytes)
    }

    private static func keyId(of dek: SymmetricKey) -> String {
        let raw = dek.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: raw)
        return digest.compactMap { String(format: "%02x", $0) }.prefix(16).joined()
    }

    private func persist(_ header: CryptoManifestHeader) {
        guard let persistenceKey,
              let data = try? JSONEncoder.wuyan.encode(header) else { return }
        Self.pendingHeaderDefaults.set(data, forKey: persistenceKey)
    }

    // MARK: - C03：测试隔离

    /// 待提交密钥头的持久化域。生产固定 standard；测试注入隔离 suite 后，
    /// 加密同步测试不再读写用户真实 defaults。
    private static var pendingHeaderDefaults: UserDefaults = .standard

    /// 仅测试目标可调用：注入隔离的 UserDefaults。
    static func injectDefaultsForTesting(_ injected: UserDefaults) {
        pendingHeaderDefaults = injected
    }

    private static func locked<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
