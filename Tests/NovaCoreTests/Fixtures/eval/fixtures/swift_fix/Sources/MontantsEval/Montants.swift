// Fixture FICTIVE du banc Nova (cas correctif_swift). Ce fichier contient volontairement un défaut.
// Règle : l'argent est compté en micro-dollars entiers (1 USD = 1 000 000 µ$), jamais en flottants,
// et un coût partiel est toujours arrondi AU-DESSUS (on ne sous-estime jamais une dépense).

/// Coût en micro-dollars de `jetons` jetons facturés `prixMicroParMillion` µ$ par million de jetons.
public func coutMicroDollars(jetons: Int, prixMicroParMillion: Int64) -> Int64 {
    let usd = Double(jetons) * Double(prixMicroParMillion) / 1_000_000
    return Int64(usd)
}

/// Coût total d'une liste d'appels (jetons, prix).
public func coutTotalMicroDollars(_ appels: [(jetons: Int, prixMicroParMillion: Int64)]) -> Int64 {
    var total: Int64 = 0
    for a in appels { total += coutMicroDollars(jetons: a.jetons, prixMicroParMillion: a.prixMicroParMillion) }
    return total
}
