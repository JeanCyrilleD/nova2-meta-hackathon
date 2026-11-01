import Foundation
import Security
import LocalAuthentication
import NovaCore

/// PHASE 4 (31/10/2026) — éléments de Trousseau à déverrouillage BIOMÉTRIQUE pour le coffre (protocole dans
/// NovaCore/VaultBiometric.swift). Contrôle d'accès `.biometryCurrentSet` : Touch ID obligatoire à chaque lecture,
/// et l'élément devient illisible si les empreintes du Mac changent. Trousseau à protection de données
/// (kSecUseDataProtectionKeychain) : le seul qui applique SecAccessControl sur macOS — il exige que l'app soit
/// signée avec le droit « keychain-access-groups » (sinon OSStatus -34018, remonté tel quel, rien n'est écrit).
/// Aucune valeur n'est journalisée ni renvoyée à l'interface ; ce fichier ne fait que ranger/relire des octets.
final class BiometricKeychain: BiometricSecretStore {
    func availability() -> (ok: Bool, kind: String, message: String) {
        let c = LAContext()
        var err: NSError? = nil
        let ok: Bool = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        if ok && c.biometryType == .touchID { return (true, "touchid", "") }
        return (false, "aucune", err?.localizedDescription ?? "aucun capteur Touch ID ou aucune empreinte enregistrée")
    }

    private func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    func exists(service: String, account: String) -> Bool {
        // Contexte sans interaction : l'élément protégé répond « interaction non permise » s'il existe — aucune donnée lue.
        let c = LAContext()
        c.interactionNotAllowed = true
        var q: [String: Any] = base(service, account)
        q[kSecUseAuthenticationContext as String] = c
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let st: OSStatus = SecItemCopyMatching(q as CFDictionary, nil)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    func store(service: String, account: String, data: Data) -> Int32 {
        var cfErr: Unmanaged<CFError>? = nil
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &cfErr) else {
            _ = cfErr?.takeRetainedValue()
            return errSecParam
        }
        var q: [String: Any] = base(service, account)
        q[kSecAttrLabel as String] = "Nova — clé du coffre (AES-256, Touch ID)"
        q[kSecAttrAccessControl as String] = ac
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil)
    }

    func read(service: String, account: String, reason: String) -> (status: Int32, data: Data?) {
        let c = LAContext()
        c.localizedReason = reason
        c.localizedCancelTitle = "Annuler"
        var q: [String: Any] = base(service, account)
        q[kSecUseAuthenticationContext as String] = c
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef? = nil
        let st: OSStatus = SecItemCopyMatching(q as CFDictionary, &out)   // macOS affiche l'invite Touch ID ici
        return (st, st == errSecSuccess ? out as? Data : nil)
    }
}
