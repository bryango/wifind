import Foundation
import Security

/// Reads the Wi-Fi credential macOS stored for a network. This is the same
/// item the system Wi-Fi menu uses; we never write to it.
public enum Keychain {
    public enum LookupResult {
        case found(String)
        case missing
        case denied(String)
        case failed(String)
    }

    public static func password(for ssid: String) -> LookupResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrDescription as String: "AirPort network password",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                return .found(text)
            }
            return .failed("keychain returned non-UTF8 data")
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed:
            return .denied("keychain access was not allowed")
        default:
            return .failed("SecItemCopyMatching status \(status)")
        }
    }
}
