import CommonCrypto
import CryptoKit
import Foundation

struct KDFParams: Codable, Equatable {
    var salt: Data
    var iterations: Int = 210_000
    var kdfAlgorithm: String = "PBKDF2-HMAC-SHA256"
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
        let iterations = max(1, params.iterations)
        var derivedKey = Data(count: 32)  // dkLen = 32 bytes = 1 个 SHA256 块

        derivedKey.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase,
                    passphrase.utf8.count,
                    saltPtr.baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedPtr.baseAddress,
                    32
                )
            }
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
