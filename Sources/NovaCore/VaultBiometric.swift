import Foundation
#if os(macOS)
import CryptoKit
#endif

/// PHASE 4 (31/10/2026) — Coffre derrière Touch ID par le TROUSSEAU lui-même.
///
/// Avant : la clé AES-256 du coffre est un élément de Trousseau classique (lisible sans invite par l'app signée) ;
/// Touch ID n'était qu'une porte LAContext DEVANT la lecture. Ici : une copie de la clé peut être rangée dans un élément
/// à CONTRÔLE D'ACCÈS biométrique (SecAccessControl .biometryCurrentSet, Trousseau à protection de données) — le
/// système refuse alors de rendre la clé sans Touch ID, quel que soit le code qui la demande.
///
/// • L'implémentation Security/LocalAuthentication vit dans NovaMac (BiometricKeychain.swift) et s'enregistre ici au
///   démarrage ; NovaCore ne voit qu'un protocole (testable, et rien sous Linux).
/// • Opt-in explicite : POST /api/vault/biometric/enable (coffre ouvert). Rien n'est supprimé : l'ancien élément reste
///   au Trousseau tant qu'Ahadi n'a pas décidé de le retirer (geste destructif sur un identifiant : règle 0.4).
/// • Aucune valeur n'est jamais renvoyée, journalisée ni affichée : statuts, booléens et codes OSStatus seulement.
/// • Couper : POST /api/vault/biometric/disable (repasse sur l'élément classique), ou retirer l'appel
///   `VaultBiometric.register(...)` de NovaMac/main.swift (sans implémentation enregistrée, tout est inerte).
public protocol BiometricSecretStore: AnyObject {
    /// (disponible, "touchid" | "aucune", message lisible)
    func availability() -> (ok: Bool, kind: String, message: String)
    /// Présence de l'élément SANS invite (aucune donnée lue).
    func exists(service: String, account: String) -> Bool
    /// Range `data` dans un élément biométrique (échoue si l'élément existe). Renvoie un OSStatus.
    func store(service: String, account: String, data: Data) -> Int32
    /// Lit l'élément ; macOS affiche l'invite Touch ID avec `reason`. (OSStatus, données) — données jamais journalisées.
    func read(service: String, account: String, reason: String) -> (status: Int32, data: Data?)
}

public enum VaultBiometric {
    static let service: String = "nova-vault-key-bio"
    static let account: String = "nova-coffre-aes256"
    final class Box: @unchecked Sendable { let lock = NSLock(); var store: BiometricSecretStore? = nil }   // accès sous `lock` seulement
    static let box: Box = Box()

    public static func register(_ s: BiometricSecretStore) { box.lock.lock(); box.store = s; box.lock.unlock() }
    static func impl() -> BiometricSecretStore? { box.lock.lock(); defer { box.lock.unlock() }; return box.store }
    /// Le coffre lit-il sa clé dans l'élément biométrique ? (réglage persisté dans vault_config.json, aucune donnée)
    static func enabled() -> Bool { ((VaultCrypto.cfg.read(default: [String: Any]()) as [String: Any])["key_store"] as? String) == "biometric" }

    /// Clé du coffre lue derrière Touch ID. nil + message si indisponible ou refusée (aucun repli silencieux).
    static func readKey(reason: String) -> (data: Data?, error: String?) {
        guard let s = impl() else { return (nil, "Touch ID du Trousseau non branché (NovaMac n'a pas enregistré l'implémentation)") }
        let r = s.read(service: service, account: account, reason: reason)
        if r.status == 0, let d = r.data { return (d, nil) }
        if r.status == -128 { return (nil, "ouverture annulée") }   // errSecUserCanceled
        return (nil, "Trousseau biométrique : lecture refusée ou impossible (OSStatus \(r.status))")
    }
}

extension NovaApp {
    func vaultBiometricRoutes() {
        let s = server
        let sess: VaultSession = VaultSession.shared
        func journal(_ what: String, ok: Bool, _ detail: String) {
            _ = BlackBox.record(["tool": "coffre", "actor": "Ahadi", "effect": "écriture", "ok": ok, "why": what, "result": detail])
        }
        s.on("GET", "/api/vault/biometric/status") { _, res in
            guard let b = VaultBiometric.impl() else {
                res.json(["registered": false, "enabled": VaultBiometric.enabled(), "message": "implémentation absente (plateforme ou build sans NovaMac)"]); return
            }
            let a = b.availability()
            res.json(["registered": true, "available": a.ok, "biometry": a.kind, "message": a.message,
                      "enabled": VaultBiometric.enabled(), "item_present": b.exists(service: VaultBiometric.service, account: VaultBiometric.account),
                      "legacy_item_kept": true,
                      "note": "L'élément classique « nova-vault-key » est conservé : le retirer est un geste destructif qui attend l'accord d'Ahadi."])
        }
        // Copie la clé du coffre OUVERT dans l'élément biométrique, la relit derrière Touch ID, compare l'empreinte, puis bascule.
        s.on("POST", "/api/vault/biometric/enable") { req, res in
            #if os(macOS)
            guard sess.check(req.headers["x-vault"] ?? "", touch: true) else { res.json(["error": "coffre verrouillé : ouvre-le d'abord"], status: 401); return }
            guard let b = VaultBiometric.impl() else { res.json(["error": "Touch ID du Trousseau non branché"], status: 409); return }
            let a = b.availability()
            guard a.ok, a.kind == "touchid" else { res.json(["error": "Touch ID indisponible : " + a.message], status: 409); return }
            VaultCrypto.io.lock()
            let keyData: Data? = VaultCrypto.key.map { VaultCrypto.keyBytes($0) }
            let fpWant: String? = VaultCrypto.key.map { VaultCrypto.fingerprint($0) }
            VaultCrypto.io.unlock()
            guard let kd = keyData, let want = fpWant else { res.json(["error": "clé du coffre non chargée (coffre en clair ?) : rien n'est copié"], status: 409); return }
            if b.exists(service: VaultBiometric.service, account: VaultBiometric.account) {
                res.json(["error": "un élément biométrique existe déjà : rien n'est écrasé"], status: 409); return
            }
            let st: Int32 = b.store(service: VaultBiometric.service, account: VaultBiometric.account, data: kd)
            guard st == 0 else {
                let why: String = st == -34018 ? "droit « keychain-access-groups » absent de la signature (Trousseau à protection de données)" : "OSStatus \(st)"
                journal("coffre : Touch ID du Trousseau non activé", ok: false, why)
                res.json(["error": "enregistrement impossible : " + why, "status": Int(st)], status: 500); return
            }
            let back = VaultBiometric.readKey(reason: "vérifier la nouvelle clé du coffre de Nova")
            guard let bd = back.data, bd.count == 32, VaultCrypto.fingerprint(SymmetricKey(data: bd)) == want else {
                journal("coffre : Touch ID du Trousseau non activé", ok: false, "relecture refusée ou différente")
                res.json(["error": "relecture de vérification refusée ou différente : le coffre reste sur l'élément classique (" + (back.error ?? "empreinte différente") + ")"], status: 409); return
            }
            var c: [String: Any] = VaultCrypto.cfg.read(default: [String: Any]())
            c["key_store"] = "biometric"; c["key_store_since"] = nowISO()
            VaultCrypto.cfg.write(c)
            journal("coffre : clé derrière Touch ID (Trousseau)", ok: true, "élément biométrique vérifié ; élément classique conservé")
            res.json(["ok": true, "enabled": true, "legacy_item_kept": true])
            #else
            res.json(["error": "Touch ID indisponible sur cette plateforme"], status: 409)
            #endif
        }
        s.on("POST", "/api/vault/biometric/disable") { req, res in
            guard sess.check(req.headers["x-vault"] ?? "", touch: true) else { res.json(["error": "coffre verrouillé : ouvre-le d'abord"], status: 401); return }
            var c: [String: Any] = VaultCrypto.cfg.read(default: [String: Any]())
            c["key_store"] = "legacy"
            VaultCrypto.cfg.write(c)
            journal("coffre : retour à l'élément classique", ok: true, "aucun élément supprimé")
            res.json(["ok": true, "enabled": false])
        }
    }
}
