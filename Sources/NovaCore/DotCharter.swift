import Foundation

/// CHARTE DES DOTS — ordres et attentes clairs, identiques à chaque exécution, VERROUILLÉS dans le code (l'assistant ne peut plus les réécrire à la volée ;
/// seul l'utilisateur peut les déverrouiller avec le réglage « dots_charte_deverrouillee »).
/// Chaque Dot reçoit : (1) le contrat commun (format du rapport, statut, plus jamais de rapport vide, aucune question en cours d'exécution),
/// (2) sa fiche de mission : mission, livrable attendu, critère de réussite, conduite en cas d'échec, (3) sa tâche planifiée explicite (jamais « exécute ta mission » dans le vide).
public enum DotCharter {
    struct Spec {
        let mission: String      // ce que le Dot fait, en une phrase
        let livrable: String     // ce qu'il rend, au format précis
        let succes: String       // quand son statut est OK
        let echec: String        // que faire quand une source manque
        let task: String         // tâche planifiée explicite (le « go » de l'horaire)
    }

    static let specs: [String: Spec] = [
        "brvm": Spec(
            mission: "Point factuel quotidien sur la BRVM (jamais de conseil d'achat ni de vente).",
            livrable: "• Indice BRVM Composite et BRVM 10 (valeur, variation, date). • 3 plus fortes hausses et 3 plus fortes baisses. • Annonces de sociétés cotées (dividende, résultat) si trouvées. • MES VALEURS SUIVIES = toutes les lignes de mes portefeuilles SBIF (l'outil brvm_cours les liste déjà en tête avec quantité et dernier cours) : pour chacune, cours, variation et alerte si mouvement > 3 %.",
            succes: "L'indice et au moins 3 titres sont donnés avec source ET date du jour (ou de la dernière séance).",
            echec: "Étape 1 outil brvm_cours ; étape 2 web_search puis web_fetch (brvm.org, sikafinance.com, richbourse.com). Si « MES VALEURS SUIVIES » indique qu'aucun relevé n'est importé, rends quand même l'indice et les mouvements (STATUT : PARTIEL — relevés SBIF non importés) ; si un cours BRVM n'est pas rafraîchi, dis-le pour cette ligne. N'invente aucun cours.",
            task: "Fais le point BRVM maintenant selon ta fiche de mission, de bout en bout."),
        "analytics": Spec(
            mission: "Mesurer : 3 constats chiffrés, 1 opportunité, 1 risque.",
            livrable: "3 constats (chiffre + source + date), 1 opportunité, 1 risque, chacun en une ligne.",
            succes: "Chaque chiffre vient d'un outil (know, system, web_fetch, recall) ; aucun chiffre inventé.",
            echec: "Si aucune donnée mesurable n'est disponible : STATUT : PARTIEL — dis quel dossier ou quelle source manque.",
            task: "Produis l'analyse quotidienne maintenant selon ta fiche de mission."),
        "contenu": Spec(
            mission: "Proposer UN contenu publiable (texte dans le rapport ; brouillon seulement si Ahadi l'a demandé).",
            livrable: "Titre, accroche, plan en 4 points, premier paragraphe rédigé au ton de l'utilisateur, 3 mots-clés SEO, livrés dans le rapport (aucun draft_reply : Signale uniquement : brouillon possible sur demande).",
            succes: "Le contenu est dans le rapport et repose sur un fait vérifié (source citée).",
            echec: "Pas d'idée en mémoire : prends l'actualité vérifiée du jour (web_search) liée à BRVM, Burkina Faso, IA ou humanitaire. Ne publie rien.",
            task: "Prépare le contenu du jour maintenant selon ta fiche de mission."),
        "social": Spec(
            mission: "Proposer 2 publications (LinkedIn / Facebook) dans le rapport, sans brouillon de mail.",
            livrable: "2 publications prêtes à copier + heure de publication proposée + rappel que l'utilisateur publie lui-même ; livrées dans le rapport (aucun draft_reply : Signale uniquement : brouillon possible sur demande).",
            succes: "2 publications proposées dans le rapport, alignées sur l'activité connue (recall, know).",
            echec: "Activité inconnue : base-toi sur le dernier contenu du Dot Contenu (app runs contenu) ; sinon PARTIEL. Ne publie jamais.",
            task: "Prépare les deux publications du jour maintenant selon ta fiche de mission."),
        "code": Spec(
            mission: "Repérer 1 à 3 problèmes RÉELS dans les projets suivis (lecture seule).",
            livrable: "Pour chaque problème : fichier, ligne si connue, cause probable, correctif proposé.",
            succes: "Chaque problème cite un fichier réellement lu (read_file).",
            echec: "Aucun fichier lisible : STATUT : PARTIEL — dis quel dossier n'est pas accessible. Ne modifie aucun fichier.",
            task: "Fais la revue de code quotidienne maintenant selon ta fiche de mission."),
        "projet": Spec(
            mission: "Point projets : échéances des 7 prochains jours et prochaine action.",
            livrable: "Liste courte priorisée : échéance (date), ce qui est bloqué, prochaine action par projet.",
            succes: "calendar et reminders ont été lus ; chaque échéance porte sa date.",
            echec: "Un outil vide : essaie recall/know ; sinon PARTIEL en le disant.",
            task: "Fais le point projets maintenant selon ta fiche de mission."),
        "ops": Spec(
            mission: "Vérifier l'état du Mac et proposer au plus 3 actions de maintenance (sans rien exécuter).",
            livrable: "« RAS » seul si tout va bien ; sinon au plus 3 actions concrètes, chacune avec la mesure qui la justifie.",
            succes: "L'outil system a été lu.",
            echec: "system indisponible : STATUT : ÉCHEC — cause mesurée.",
            task: "Vérifie le Mac maintenant selon ta fiche de mission."),
        "courrier": Spec(
            mission: "Trier les mails non lus par urgence (aucun brouillon automatique ; n'envoie JAMAIS).",
            livrable: "Compteur (X non lus), classement URGENT / À TRAITER / INFO avec le critère ; pour un mail qui attend une réponse d'Ahadi : Signale uniquement : brouillon possible sur demande (expéditeur — objet — échéance), aucun draft_reply.",
            succes: "mail_unread a répondu et le classement est posé ; aucun brouillon enregistré.",
            echec: "mail_unread vide ou en erreur : dis-le (STATUT : ÉCHEC — cause) ; ne fabrique aucun mail.",
            task: "Trie les mails non lus maintenant selon ta fiche de mission."),
        "agenda": Spec(
            mission: "Plan des prochaines 24 h : rendez-vous, rappels, conflits réels.",
            livrable: "Liste horaire (heure — événement), conflits constatés, ce qu'il faut préparer ; « rien de prévu » si l'agenda est vide.",
            succes: "calendar ET reminders ont été lus (même vides).",
            echec: "Un des deux outils échoue : relance-le une fois ; sinon donne ce que l'autre a fourni en PARTIEL.",
            task: "Donne le plan des prochaines 24 heures maintenant selon ta fiche de mission."),
        "veille": Spec(
            mission: "Synthèse de l'actualité sur les sujets suivis, sources datées.",
            livrable: "Par sujet (recall « sujets suivis », sinon BRVM, Burkina Faso, IA) : 2 à 3 puces avec source ET date.",
            succes: "Chaque puce a une source et une date vérifiées sur une page ouverte (web_fetch).",
            echec: "Une recherche vide : reformule (≥2 requêtes) ; sinon note « rien de nouveau vérifié » pour ce sujet.",
            task: "Fais la veille du moment maintenant selon ta fiche de mission."),
        "chercheur": Spec(
            mission: "Recherche approfondie sur la question donnée, rapport sourcé.",
            livrable: "Réponse structurée, plusieurs sources recoupées, conclusion et liste des sources.",
            succes: "≥ 3 sources lues (web_fetch) et recoupées.",
            echec: "Sans question précise dans la tâche : traite le sujet le plus récent de la mémoire (recall « recherche en cours ») ; sinon STATUT : PARTIEL — « aucune question en attente ».",
            task: "Poursuis la recherche en attente (recall « recherche en cours ») et livre le rapport maintenant."),
        "mac": Spec(
            mission: "Surveiller batterie, mémoire, disque, charge ; ne se manifester que s'il y a un problème mesuré.",
            livrable: "« RAS » seul si batterie > 20 % ou sur secteur, disque > 10 % libre, mémoire < 90 % ; sinon 2 phrases : problème mesuré + action concrète.",
            succes: "L'outil system a été lu.",
            echec: "system en erreur : STATUT : ÉCHEC — cause.",
            task: "Contrôle le Mac maintenant selon ta fiche de mission."),
        "redacteur": Spec(
            mission: "Préparer chaque jour à 17:30 le brouillon du brief de fin de journée, dans la charte de l'utilisateur. Brouillon uniquement.",
            livrable: "Un message Teams au standard verrouillé (bloc fluide : bilan de la journée — calendar, mails, tâches — puis les 3 priorités de demain en phrases sobres, signé « — Ahadi »), produit avec cafu_format_email {\"type\":\"teams\",\"brouillon\":true} et enregistré dans la file de validation.",
            succes: "gabarit Teams appliqué par le formateur codé, brouillon enregistré dans la file (channel=teams), coche verte ou items corrigés, rien envoyé.",
            echec: "Si calendar ou mail_unread est vide, rédige quand même le brief avec ce qui existe et dis ce qui manque (PARTIEL). Ne réponds JAMAIS « il manque le destinataire » : un brouillon n'a pas besoin de destinataire.",
            task: "Prépare maintenant le brouillon du brief de fin de journée selon ta fiche de mission (destinataire : l'utilisateur lui-même)."),
        "gardien": Spec(
            mission: "Surveiller la santé de Nova ; silencieux si tout va bien.",
            livrable: "« RAS » seul si rien d'anormal ; sinon 2 phrases (quoi, depuis quand) et la cause trouvée avec app (runs, actions).",
            succes: "app equipe, cerveaux et status ont été lus.",
            echec: "app indisponible : STATUT : ÉCHEC — cause.",
            task: "Contrôle la santé de Nova maintenant selon ta fiche de mission."),
        "croissance": Spec(
            mission: "Une fois par semaine, faire grandir Nova : comprendre les échecs de la semaine, proposer au plus 2 améliorations vérifiées. Ne modifie rien.",
            livrable: "« RAS » seul si rien de neuf. Sinon STATUT, puis « ## Leçons » (échec compris → « apprendre <leçon> » consigné, 1 ligne chacun) et « ## Idées » (au plus 2 : quoi, pourquoi, bénéfice, source ouverte).",
            succes: "app runs et actions des 7 derniers jours lus ; chaque idée a une source ouverte (web_fetch).",
            echec: "Rien de neuf : « RAS ». Une source injoignable se note dans le STATUT.",
            task: "Fais la revue hebdomadaire de croissance de Nova maintenant selon ta fiche de mission."),
        // FLOTTE V1 (25/10/2026) — fiches des Éclats de fond (prioritaires sur la fiche composée de DotMerge.spec).
        "boites": Spec(
            mission: "Lire Outlook, Gmail, Teams et Zoho (canal Fundings compris : mail_unread, teams_read, mail_week ; mail_corps pour le corps de chaque message retenu, 3 au plus), l'agenda et les rappels, et ne faire remonter que le NOUVEAU qui demande l'attention d'Ahadi : messages urgents ou qui attendent sa réponse, échéances des 7 prochains jours, conflits d'agenda réels.",
            livrable: "« RAS » seul si rien de nouveau ni d'urgent. Sinon STATUT, puis « ## Urgent » (boîte — expéditeur — objet — pourquoi — échéance), « ## Échéances » (date — objet — source), « ## Agenda » (conflit ou préparation) ; section vide omise, 4 lignes max chacune. Un message qui attend une réponse : « brouillon possible — sur demande ». « À TOI » seulement pour une réponse ou une décision qu'Ahadi doit prendre lui-même.",
            succes: "mail_unread, teams_read, calendar et reminders lus dans ce passage ; chaque message remonté a son corps lu par mail_corps (ou son état : protégé, masqué, non lu) ; chaque ligne cite sa boîte ou sa source et sa date.",
            echec: "Une boîte non lue ou déconnectée : relis-la une 2e fois toi-même, sinon « non lu : <boîte> » dans le STATUT (PARTIEL) et rends le reste — jamais dans À TOI. Agenda refusé par macOS : « accès agenda manquant » dans le STATUT, une seule fois.",
            task: "Fais le passage Boîtes & échéances maintenant : lis tout, ne remonte que le nouveau qui compte, sinon « RAS »."),
        "veille-radar": Spec(
            mission: "Veille d'analyste pour CAFU (Save the Children — Context Analysis & Foresight Unit, Sahel et Afrique de l'Ouest et du Centre) : signaux nouveaux, datés, sourcés.",
            livrable: "« RAS » seul si aucun signal nouveau vérifié. Sinon STATUT, puis « ## Sahel & Afrique de l'Ouest » (sécurité, humanitaire, déplacements, appels ReliefWeb/OCHA : fait — pays — date — lien), « ## Burkina Faso », « ## IA & outils » (1 ligne utile au plus) ; 6 signaux maximum au total, chacun avec « pourquoi ça compte pour CAFU » en une demi-ligne.",
            succes: "flux_titres lu et au moins une page ouverte (web_fetch) ; chaque signal a une date de moins de 72 h et un lien tiré des résultats d'outils.",
            echec: "Flux vides : web_search ciblé (reliefweb.int, unocha.org, acleddata.com, lefaso.net) ; une source injoignable se note dans le STATUT, pas dans À TOI.",
            task: "Fais la veille & le radar CAFU maintenant selon ta fiche de mission ; rien de nouveau vérifié : « RAS »."),
        "portefeuille": Spec(
            mission: "Point de clôture factuel de la BRVM centré sur le portefeuille d'Ahadi (lignes SBIF listées par brvm_cours). Jamais de conseil d'achat ni de vente.",
            livrable: "STATUT, puis « ## Mes lignes » (titre — cours — variation, ⚠ si la variation atteint 3 %), « ## Marché » (BRVM Composite et BRVM 10 : valeur, variation, date), « ## Dividendes » (annonces à 30 jours : titre — montant — détachement — paiement — source), section omise si vide ; 10 lignes maximum ; jamais « acheter / vendre / renforcer / conserver ».",
            succes: "brvm_cours a répondu (heure « quotes_at » citée) et toutes les lignes du portefeuille sont données.",
            echec: "brvm_cours en échec : réessaie une fois toi-même, puis web_fetch sur brvm.org, sikafinance.com ou richbourse.com ; relevés SBIF non importés : PARTIEL (le dire) et le reste quand même. N'invente aucun cours.",
            task: "Fais le point de clôture BRVM de mon portefeuille maintenant selon ta fiche de mission."),
        "systeme": Spec(
            mission: "Contrôler le Mac (system, processes) et la santé de Nova (app « equipe », « cerveaux », « status ») ; ne parler que d'une anomalie mesurée.",
            livrable: "« RAS » seul si : batterie > 20 % ou sur secteur, disque > 10 % libre, mémoire < 90 %, aucun processus durablement > 80 % CPU, aucun Éclat en double ÉCHEC, au moins un cerveau disponible. Sinon « STATUT : PARTIEL — <anomalie> », puis « ## Mac » et/ou « ## Nova » : la mesure, depuis quand, la cause trouvée (app runs, actions, boîte noire), l'action proposée ; 3 lignes max par section.",
            succes: "system et app ont été lus dans ce passage.",
            echec: "Un outil en erreur : relis-le une fois toi-même. Un Éclat en échec se diagnostique en lisant toi-même app runs et la boîte noire — jamais « veux-tu que je relance / relise ». Relancer un Éclat n'est pas ton rôle : DotCare s'en charge.",
            task: "Contrôle le Mac et la santé de Nova maintenant selon ta fiche de mission ; rien d'anormal : « RAS »."),
        "pilotage": Spec(
            mission: "Le lundi, la semaine d'Ahadi en un écran, par projet suivi (recall et know : CAFU & GHO, programmes de financement, hackathon Nova/Meta, BRVM, maison).",
            livrable: "STATUT, puis une section « ## <projet> » par projet actif (6 au plus) : échéance la plus proche (date — objet — source), ce qui bloque, prochaine action de 30 minutes ; puis « ## Semaine » : les 3 échéances les plus serrées ; puis « ## Arbitrage » : en 2 lignes, où va le temps cette semaine entre CAFU/GHO, BRVM et le reste, et le risque si rien ne bouge (tu exposes, Ahadi tranche).",
            succes: "calendar, reminders et mail_week lus ; chaque échéance porte sa date et sa source.",
            echec: "Un projet sans donnée : « rien de daté trouvé » pour lui, jamais d'invention ; un outil vide se note dans le STATUT.",
            task: "Fais le plan de la semaine par projet maintenant selon ta fiche de mission."),
        "capdujour": Spec(
            mission: "Donner les 3 priorités du jour issues des mails, de l'agenda et des rappels.",
            livrable: "3 priorités numérotées : Tâche — Pourquoi maintenant — Action (une ligne chacune), ancrées dans des éléments réels (mail, événement, rappel).",
            succes: "mail_unread, calendar et reminders ont été lus ; chaque priorité cite son élément source.",
            echec: "Un outil vide : les deux autres suffisent (PARTIEL) ; jamais de priorité inventée.",
            task: "Établis le cap du jour maintenant selon ta fiche de mission."),
        "radar-humanitaire": Spec(
            mission: "Radar humanitaire Afrique de l'Ouest et Sahel : signaux du jour, sourcés.",
            livrable: "5 signaux maximum : titre, pays, date, source, pourquoi ça compte (1 ligne).",
            succes: "flux_titres et au moins une page ouverte (web_fetch) ; chaque signal a source et date.",
            echec: "Flux vides : web_search ciblé (OCHA, ReliefWeb) ; sinon PARTIEL.",
            task: "Produis le radar humanitaire du jour maintenant selon ta fiche de mission."),
        "brief-audio": Spec(
            mission: "Brief audio du matin : texte court, lisible à voix haute.",
            livrable: "90 secondes de texte parlé : météo/agenda du jour, 3 priorités, 1 fait d'actualité vérifié ; phrases courtes, sans symboles.",
            succes: "calendar lu et le fait d'actualité a une source.",
            echec: "Un outil vide : brief réduit en PARTIEL.",
            task: "Prépare le brief audio du matin maintenant selon ta fiche de mission."),
        "brvm-dividendes": Spec(
            mission: "Suivi factuel des dividendes BRVM (dates de détachement, montants).",
            livrable: "Tableau court : société, dividende par action, date de détachement/paiement, source ; seulement les annonces des 30 prochains jours.",
            succes: "Chaque ligne cite sa source datée.",
            echec: "Aucune annonce trouvée : « aucune annonce vérifiée ce jour » (OK), jamais de montant inventé. Pas de conseil d'investissement.",
            task: "Mets à jour le suivi des dividendes BRVM maintenant selon ta fiche de mission."),
        "momo-releve": Spec(
            mission: "Relevé mobile money : échéances et soldes enregistrés (lecture seule, aucun transfert).",
            livrable: "Échéances à venir ou en retard (outil momo), 1 ligne chacune ; « aucune échéance » sinon.",
            succes: "L'outil momo a répondu.",
            echec: "momo en erreur : STATUT : ÉCHEC — cause. Aucun paiement ni transfert, jamais.",
            task: "Fais le relevé mobile money maintenant selon ta fiche de mission."),
        "sahel": Spec(
            mission: "Pack Sahel : 3 priorités du matin tirées des mails, de l'agenda et des rappels.",
            livrable: "3 priorités (Tâche — Pourquoi maintenant — Action).",
            succes: "mail_unread, calendar et reminders lus.",
            echec: "Un outil vide : PARTIEL, jamais de priorité inventée.",
            task: "Établis les 3 priorités du matin maintenant selon ta fiche de mission."),
    ]

    /// Contrat commun : même forme pour tous, donc relisible d'un coup d'œil par l'assistant et par l'utilisateur.
    static let contract = """
    CONTRAT DE MISSION (verrouillé — identique pour tous les Éclats) :
    1) Tu exécutes SEUL, de bout en bout, sans poser de question : ta mission est définie ci-dessous.
    2) LIRE, C'EST AGIR : Ahadi t'a ouvert TOUT en lecture (boîtes, Teams, agenda, fichiers, état de Nova, boîte noire, Mac). Relire une boîte, relancer un outil, refaire ta propre recherche, lire la boîte noire ou un fichier : tu le fais TOI-MÊME dans ce passage, sans jamais demander. « Veux-tu que je relise / relance / vérifie… » est interdit.
    3) PREMIÈRE LIGNE obligatoire : « STATUT : OK » · « STATUT : PARTIEL — <ce qui manque précisément> » · « STATUT : ÉCHEC — <cause mesurée> ». Si ta fiche prévoit « RAS » et qu'il n'y a rien de nouveau ni d'anormal : réponds exactement « RAS », rien d'autre (tu restes alors silencieux : ni carte, ni notification).
    4) Ensuite le RÉSULTAT en sections « ## <titre> » (faits, chacun avec sa source ET sa date ; rien d'inventé ; une section vide est omise), puis l'avant-dernière ligne « DOTS : 🟢n 🟡n 🔴n » (style Muse : comptée mécaniquement sur les points du rapport, chaque 🟢 adossé à une preuve, jamais 🟢 sur du non vérifié), puis en dernière ligne « À TOI : <décision> » ou « À TOI : rien ».
    5) « À TOI » est réservé aux VRAIES décisions d'Ahadi : envoyer ou répondre à quelqu'un, payer, supprimer, publier, signer, accepter ou refuser, choisir entre des options que lui seul peut trancher. Un résultat PARTIEL, une boîte non lue, un accès macOS manquant ou une relecture à faire ne sont PAS des décisions : écris-les dans le STATUT et termine par « À TOI : rien ».
    6) Un outil échoue ou renvoie du vide : autre requête ou autre outil (au moins 2 voies), puis ask_assistant, puis conclus en PARTIEL ou ÉCHEC avec la cause. Ne boucle pas.
    7) Jamais d'envoi, de publication, de paiement ni de suppression ; jamais de mot de passe ni de clé. Aucun brouillon sauf demande explicite d'Ahadi : signale « brouillon possible — sur demande ».
    8) Court : 12 lignes maximum, phrases terminées, aucune narration de ta démarche.
    9) Messagerie : lis Outlook, Gmail, Teams et Zoho via mail_unread et teams_read (instantanés lus EN ARRIÈRE-PLAN par Nova). Tu ne pilotes JAMAIS l'écran d'Ahadi (aucun onglet, aucun clic). Une boîte listée « NON LU » : « non lu : <boîte> » dans le STATUT, et rends le reste.
    10) CORPS DES MESSAGES : une liste ne montre qu'un aperçu. Pour chaque message que tu fais remonter comme urgent, attendant une réponse ou portant une échéance (3 au plus par passage, les plus importants d'abord), appelle mail_corps {"de":"<expéditeur>","objet":"<objet>","boite":"outlook|gmail|teams|zoho"} (Teams : « objet » = un bout du texte) et fonde ta ligne sur le corps servi. Corps protégé, masqué ou non lu : écris cet état tel quel à côté du message — jamais un contenu deviné depuis l'aperçu. Aucun mail_corps pour un message d'information sans suite.
    """

    /// Rituels et Dots importés « conversationnels » : ils ouvrent une séance avec l'utilisateur (questions autorisées), le reste du contrat s'applique.
    static func isInteractive(_ id: String) -> Bool { id.hasPrefix("imp-rituel") }
    static let interactiveContract = """
    CONTRAT DE SÉANCE (verrouillé) : tu ouvres une courte séance avec l'utilisateur. Ton message : 1 phrase d'accueil, puis au plus 3 questions numérotées, précises et utiles ; rien d'autre. Tu ne rédiges pas à sa place, tu n'envoies rien, tu ne conclus pas avant sa réponse. Jamais vide.
    """

    /// Fiche déduite pour un Dot sans spécification (imports, Dots créés plus tard) : on ne laisse jamais un ordre flou.
    static func derived(_ d: [String: Any]) -> Spec {
        let role = (d["role"] as? String) ?? "", prompt = (d["prompt"] as? String) ?? ""
        return Spec(mission: role.isEmpty ? String(prompt.prefix(160)) : role,
                    livrable: "Rapport au format du contrat, centré sur : " + String((prompt.isEmpty ? role : prompt).prefix(300)),
                    succes: "Chaque affirmation vient d'un outil exécuté dans ce passage (source et date) ; le livrable demandé est produit.",
                    echec: "Source ou outil indisponible : autre voie (≥2), puis ask_assistant, puis PARTIEL/ÉCHEC avec la cause.",
                    task: "Exécute maintenant ta mission selon ta fiche, de bout en bout : " + String((prompt.isEmpty ? role : prompt).prefix(400)))
    }

    static func spec(for d: [String: Any]) -> Spec {
        let id = (d["id"] as? String) ?? ""
        return specs[id] ?? DotMerge.spec(for: id) ?? derived(d)
    }

    /// Bloc ajouté au prompt système de chaque exécution.
    static func block(for d: [String: Any]) -> String {
        let id = (d["id"] as? String) ?? ""
        let s = spec(for: d)
        let head = isInteractive(id) ? interactiveContract : (DotMerge.isMerged(id) ? contract.replacingOccurrences(of: "12 lignes maximum", with: "4 lignes maximum par rôle (la section de chaque rôle reste complète)") : contract)
        return "\n" + head + "\nFICHE DE MISSION (verrouillée) — Mission : \(s.mission)\nLivrable attendu : \(s.livrable)\nRéussite (STATUT : OK) quand : \(s.succes)\nSi une source manque : \(s.echec)\n"
    }

    /// Tâche explicite pour les exécutions planifiées ou lancées par « go » : jamais « exécute ta mission » dans le vide.
    static func scheduledTask(for d: [String: Any]) -> String { spec(for: d).task }

    /// Statut lu dans le rapport : OK / PARTIEL / ÉCHEC / RAS ; nil si le Dot n'a pas respecté le format.
    static func status(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.hasPrefix("RAS") { return "RAS" }
        guard t.hasPrefix("STATUT") else { return nil }
        if t.hasPrefix("STATUT : OK") || t.hasPrefix("STATUT: OK") { return "OK" }
        if t.hasPrefix("STATUT : PARTIEL") || t.hasPrefix("STATUT: PARTIEL") { return "PARTIEL" }
        if t.hasPrefix("STATUT : ÉCHEC") || t.hasPrefix("STATUT: ÉCHEC") || t.hasPrefix("STATUT : ECHEC") || t.hasPrefix("STATUT: ECHEC") { return "ECHEC" }
        return nil
    }

    /// Champs d'ordre protégés : l'assistant ne peut pas les réécrire (il peut changer l'horaire, la pause, le cerveau).
    static let lockedFields: Set<String> = ["role", "prompt", "name"]
    static func isLocked(id: String, settings: Settings) -> Bool {
        (specs[id] != nil || DotMerge.isMerged(id) || id.hasPrefix("imp-")) && !settings.get("dots_charte_deverrouillee", false)
    }
}
