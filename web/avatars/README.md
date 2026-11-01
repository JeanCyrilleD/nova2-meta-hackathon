# web/avatars/ — compagnons 3D réalistes de Nova

Ce dossier est vide tant que les personnages réalistes n'ont pas été livrés. Sans fichier valide, Nova affiche les pandas procéduraux de `web/js/mascot.js`.

## Les fichiers attendus

Les noms doivent être exacts :

- `nova_panda.glb` : le panda géant (« Nova Zen »)
- `nova_pandaroux.glb` : le panda roux (« Nova Vif »)

La spécification complète se trouve dans `conseil_24-10/CAHIER_AVATAR_3D_REALISTE.md`.

## Réception en 3 étapes

1. Dépose le ou les `.glb` dans ce dossier.
2. Depuis la racine du dépôt, lance `python3 tools/check_glb.py --installer`. Le script produit un rapport en français et écrit `manifest.json`. Un fichier refusé n'est pas activé.
3. Recompile l'app (`tools/package_app.sh`).

`manifest.json` est le seul interrupteur : `web/js/avatar.js` ne charge un `.glb` que s'il y est marqué `ok`. Le fichier repasse ensuite une validation au chargement ; si elle échoue, ou si WebGL2 est absent, c'est le panda procédural qui s'affiche.

Avec `--apercu`, les fichiers sont marqués « APERÇU » (`defaut: false`) : le panda organique reste affiché par défaut, et le .glb n'apparaît que si l'interrupteur Réglages › Avatar 3D (aperçu) est activé (réglage `avatar_3d`). C'est l'état actuel avec les fichiers de Gemini du 24/10.

Pour revenir aux pandas procéduraux, retire les `.glb` du dossier, puis relance `python3 tools/check_glb.py --installer`.
