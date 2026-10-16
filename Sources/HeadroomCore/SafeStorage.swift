import CommonCrypto
import Foundation

public enum SafeStorageError: Error, Equatable {
    case badPrefix
    case keyDerivationFailed
    case cryptFailed(Int32)
}

/// Chromium "v10" safe storage as used by Electron apps on macOS:
/// PBKDF2-HMAC-SHA1 (salt "saltysalt", 1003 rounds, 16 bytes) and AES-128-CBC with an IV of 16 spaces.
public enum SafeStorage {
    static let salt = Array("saltysalt".utf8)
    static let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    static let prefix = Array("v10".utf8)

    public static func deriveKey(password: String) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withCString { pointer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard status == Int32(kCCSuccess) else { throw SafeStorageError.keyDerivationFailed }
        return key
    }

    public static func decrypt(_ blob: Data, key: [UInt8]) throws -> Data {
        let bytes = [UInt8](blob)
        guard bytes.starts(with: prefix) else { throw SafeStorageError.badPrefix }
        return try crypt(CCOperation(kCCDecrypt), Array(bytes.dropFirst(prefix.count)), key: key)
    }

    public static func encrypt(_ plain: Data, key: [UInt8]) throws -> Data {
        Data(prefix) + (try crypt(CCOperation(kCCEncrypt), [UInt8](plain), key: key))
    }

    static func crypt(_ operation: CCOperation, _ input: [UInt8], key: [UInt8]) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &moved)
        guard status == Int32(kCCSuccess) else { throw SafeStorageError.cryptFailed(status) }
        return Data(output.prefix(moved))
    }
}
