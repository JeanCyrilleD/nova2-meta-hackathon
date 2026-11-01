# Nova 2 — Signature stable (« Nova Dev »)

## Pourquoi

`tools/package_app.sh` signait Nova.app en **ad hoc** (`codesign -s -`).
Une signature ad hoc produit un *cdhash* différent à chaque compilation :
pour macOS, chaque build est donc une application « nouvelle », et les
autorisations **TCC** déjà accordées à Nova — Calendriers, Automatisation,
Accès complet au disque, micro, etc. — sont **révoquées à chaque build**.
C'est ce qui obligeait à les ré-accorder après chaque recompilation
(constaté à chaque recette, diagnostic calendrier DIAG-CALENDRIER).

Une **identité de signature stable** règle le problème à la racine :
le certificat ne change pas d'un build à l'autre, la *designated
requirement* de l'app reste identique, et macOS conserve les
autorisations accordées.

## Le geste unique (une seule fois, sur le Mac)

Dans un Terminal, depuis la racine de Nova2 :

```bash
bash tools/setup_signing.sh
```

Le script, idempotent et prudent :

1. vérifie si une identité « Nova Dev » valide existe déjà — si oui, il ne
   fait rien (il n'écrase jamais une identité existante) ;
2. sinon, crée un certificat **auto-signé** « Nova Dev » (OpenSSL, RSA 2048,
   10 ans, usage limité à la signature de code), l'importe dans le
   trousseau de session et le déclare de confiance **uniquement pour la
   signature de code** (`security add-trusted-cert -p codeSign`) ;
3. autorise `codesign` à utiliser la clé sans invite répétée
   (`security set-key-partition-list`) ;
4. vérifie le résultat par une signature d'essai réelle.

macOS peut demander le mot de passe de session/du trousseau pendant
l'opération : il est saisi par l'utilisateur, dans le Terminal — le script
ne le lit pas, ne le reçoit pas et ne le conserve pas. Aucun mot de passe
n'est écrit dans le script ; la phrase de passe du fichier d'import
temporaire est aléatoire, gardée en mémoire et détruite à la sortie.
Aucun `sudo`, aucun réseau.

## Ce que ça change ensuite

Rien à changer aux habitudes :

```bash
bash tools/package_app.sh
```

Le script de packaging choisit automatiquement, par ordre de priorité :

1. `NOVA_SIGN_IDENTITY`, s'il est fourni (comportement antérieur, inchangé) ;
2. « Nova Dev », si l'identité est présente et valide ;
3. le repli ad hoc, sinon (comportement historique, inchangé).

La ligne affichée pendant le build dit lequel des trois cas s'applique :

```
Signature : Nova Dev (stable)
Signature : <nom> (explicite)
Signature : ad hoc (repli)
```

## Ce que ça change aux recettes

- Au **premier** build signé « Nova Dev », macOS redemandera les
  autorisations **une dernière fois** : l'identité change par rapport aux
  builds ad hoc, donc les anciennes concessions ne se transfèrent pas.
- À partir du build suivant, les autorisations accordées **persistent** :
  plus de ré-autorisation Calendriers / Automatisation / Accès complet au
  disque après chaque recompilation. Le critère d'acceptation du kit :
  après un premier build « Nova Dev » et l'accord des autorisations, un
  second build ne doit plus les invalider.

## Révoquer

Pour retirer l'identité (le packaging retombera alors en ad hoc) :

```bash
security find-certificate -c "Nova Dev" -p ~/Library/Keychains/login.keychain-db > /tmp/nova-dev.pem
security remove-trusted-cert /tmp/nova-dev.pem
security delete-certificate -c "Nova Dev" ~/Library/Keychains/login.keychain-db
rm -f /tmp/nova-dev.pem
```

(Équivalent graphique : Accès aux trousseaux → session → supprimer le
certificat « Nova Dev » et retirer sa confiance.)

## Limites honnêtes

- « Nova Dev » est une identité **auto-signée locale**, pas un certificat
  *Apple Developer ID*. Elle stabilise la signature **sur ce Mac** ; elle
  ne notarise rien et ne change rien à Gatekeeper pour une diffusion sur
  d'autres machines (premier lancement : clic droit → Ouvrir, comme avant).
- Le premier build signé avec cette identité peut encore déclencher les
  invites système sensibles (TCC) **une dernière fois** — c'est attendu,
  c'est le changement d'identité, pas un échec du kit.
- La confiance accordée est **limitée à la signature de code**
  (`-p codeSign`) : le certificat n'est pas un certificat d'autorité pour
  TLS, e-mail ou autre usage.
