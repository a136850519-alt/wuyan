import CryptoKit
import Foundation

struct KDFParams: Codable, Equatable {
    var salt: Data
    var iterations: Int = 210_000
}

protocol CryptoBox {
    func deriveKey(passphrase: String, salt: Data, params: KDFParams) throws -> SymmetricKey
    func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data
    func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data
}

struct AESGCMCryptoBox: CryptoBox {
    // PBKDF2-HMAC-SHA256（纯 CryptoKit 实现，dkLen = 32 = 1 个 SHA256 块）。
    // 取代原来仅迭代约 21 次 SHA256 的弱派生——后者可被瞬间暴力破解。
    func deriveKey(passphrase: String, salt: Data, params: KDFParams) throws -> SymmetricKey {
        let iterations = max(1, params.iterations)
        let macKey = SymmetricKey(data: Data(passphrase.utf8))

        // U1 = PRF(P, S || INT_32_BE(1))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: macKey))
        var result = u

        // U_i = PRF(P, U_{i-1}); T = U1 ^ U2 ^ … ^ Uc
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: macKey))
            for i in result.indices {
                result[i] ^= u[i]
            }
        }
        return SymmetricKey(data: result)
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
