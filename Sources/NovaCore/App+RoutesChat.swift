import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import ApplicationServices
#endif
import NovaFoundation

/* DÉCOUPAGE App.swift (29/10, engagement de découpage honoré) : routes du chat (stream, conversations, steer).
   Méthode extraite telle quelle de App.swift — extension du même type NovaApp, même module :
   ZÉRO changement de comportement. Recette : swift build + swift test + verify.sh verts. */

extension NovaApp {
    func routesChat(_ s: HTTPServer) {
        s.on("POST", "/api/chat") { [self] req, res in
            // 31/10 : tour du BANC AGENT (Feat_BancAgent.swift) — dépense comptée « banc », confirmations du moteur forcées sur ce fil.
            let bancTurn: Bool = req.headers["x-nova-banc"] == "1"
            if bancTurn { LLMSpend.setBench(true) }
            defer { if bancTurn { LLMSpend.setBench(false) } }
            LLMSpend.turnReset()   // 31/10 : coût de CETTE demande (plafond par demande, coût affiché)
            // 25/10 : la salutation dépend du dernier échange, toutes conversations confondues — mémorisé dans les
            // réglages (« last_exchange_at ») pour survivre aux relancements de l'app.
            let savedEx: Date = ISO8601DateFormatter().date(from: settings.get("last_exchange_at", "")) ?? .distantPast
            let prevExchange: Date = max(NovaApp.lastChatAt, savedEx)
            let j = req.json
            // 31/10 (diag Éclats : 23 reports « pause chat récent » dont des tours qui ne venaient pas d'Ahadi) — seul un VRAI
            // message d'Ahadi arme la pause des Éclats et la salutation : pas le banc (x-nova-banc), pas le test CAFU sans écran
            // (cafu_test), pas le rejeu au retour du réseau (x-nova-replay), pas un appel interne marqué x-nova-interne.
            let internalTurn: Bool = bancTurn || req.headers["x-nova-replay"] == "1" || req.headers["x-nova-interne"] == "1" || (j["cafu_test"] as? Bool) == true
            if !internalTurn { NovaApp.lastChatAt = Date(); settings.set(["last_exchange_at": nowISO()]) }
            guard let text = (j["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { res.json(["error": "texte vide"], status: 400); return }
            let chatT0 = Date()
            let cid = (j["conversation_id"] as? String).flatMap { convs.get($0) != nil ? $0 : nil } ?? convs.create()
            ChatRuns.begin(cid)   // 27/10 : priorité absolue au run d'Ahadi — les arrivées automatiques attendent (matérialiseur Direct, relances d'Éclats)
            defer { ChatRuns.end(cid) }
            ChatTurnGate.shared.acquire(cid)   // DIAG2-CONTEXTE P-CTX-2 : un tour à la fois par fil, dans l'ordre d'arrivée
            defer { ChatTurnGate.shared.release(cid) }
            SteerQueue.shared.begin(cid)   // V4-D : LIVE STEER — les précisions de ce fil sont acceptées pendant ce tour
            var steerClosed: Bool = false
            defer { if !steerClosed { _ = SteerQueue.shared.end(cid) } }
            if let inc = j["incognito"] as? Bool { _ = convs.setIncognito(cid, inc) }   // MÉMOIRE SOUVERAINE : « Hors mémoire » choisi avant le premier message
            let incognito: Bool = convs.isIncognito(cid)
            if incognito { MemoryLedger.beginIncognito() }
            defer { if incognito { MemoryLedger.endIncognito() } }
            let spoken = (j["voice"] as? Bool) == true
            // 27/10 : PORTE DE RELECTURE VOIX (réglage voix_conversation) — un message vocal
            // n'est jamais exécuté avant relecture. Tour en attente dans ce fil : validation
            // → le texte relu devient la demande ; annulation → accusé sans exécution ;
            // autre texte → correction exécutée telle quelle. Nouveau message vocal :
            // transcription montrée, rien n'est lancé.
            var askText: String = text
            if VoixConversation.estActif(settings) {
                let vc = VoixConversation.shared
                if let pending = vc.tourEnAttente(cid: cid) {
                    if VoixConversation.estAnnulation(text) {
                        _ = vc.rejeterTour(id: pending.id); vc.delier(cid: cid)
                        _ = convs.append(cid, role: "user", content: text)
                        let ack: String = "Compris — je laisse tomber cette demande, rien n'a été lancé."
                        _ = convs.checkpoint(cid, content: ack, brain: "relecture voix", final: true)
                        res.sseStart(); res.sse("meta", ["conversation_id": cid]); res.sse("delta", ["t": ack]); res.sse("done", ["relecture": pending.id, "etat": "rejete"])
                        return
                    } else if VoixConversation.estValidation(text) {
                        _ = vc.validerTour(id: pending.id)
                        if let relu: String = vc.texteExecutable(id: pending.id) { askText = relu }
                        _ = vc.marquerExecute(id: pending.id); vc.delier(cid: cid)
                    } else {
                        _ = vc.rejeterTour(id: pending.id); vc.delier(cid: cid)   // correction : le nouveau texte fait foi
                    }
                } else if spoken {
                    let debut = vc.demarrerTour(actif: true)
                    if let tid: Int = debut.id {
                        vc.cloreTourUtilisateur(id: tid, texteFinal: text); vc.lierConversation(id: tid, cid: cid)
                        _ = convs.append(cid, role: "user", content: text)
                        let shown: String = "🗣️ Voici ce que j'ai entendu :\n« " + text + " »\n\nDis « valide » pour que je l'exécute, corrige-moi en réécrivant ta demande, ou dis « annule » pour laisser tomber. Rien n'a été lancé."
                        _ = convs.checkpoint(cid, content: shown, brain: "relecture voix", final: true)
                        res.sseStart(); res.sse("meta", ["conversation_id": cid]); res.sse("delta", ["t": shown]); res.sse("done", ["relecture": tid, "etat": "en_attente"])
                        return
                    }
                }
            }
            let remote = req.headers["x-nova-remote"] == "1"   // depuis le téléphone : jamais d'outils (pas d'actions sur le Mac)
            let useTools = remote ? false : ((j["tools"] as? Bool) ?? true)
            // WP3-M (31/10) : CONTEXTE D'EXÉCUTION DU RUN (remplace les fenêtres globales sendUntil / frontUntil / freeUntil).
            // Source : téléphone → phone (politique existante : jamais d'action sur le Mac) ; banc / rejeu automatique →
            // background (ne crée jamais d'approbation) ; sinon chat, ou voix pour un message parlé.
            let execSrc: ExecSource = remote ? .phone : ((bancTurn || req.headers["x-nova-replay"] == "1") ? .background : (spoken ? .voice : .chat))
            let execCtx: ExecContext = ExecContext(conversationId: cid, source: execSrc, actor: "Nova")
            let execPrev: ExecContext? = ExecContext.enter(execCtx)
            defer { ExecContext.restore(execPrev) }
            let demoOn: Bool = settings.get("demo_mode", false)   // MN2-8 : lu AVANT l'émission meta
            let priorMsgs: [[String: Any]] = (convs.get(cid)?["messages"] as? [[String: Any]]) ?? []
            let firstMessage: Bool = !priorMsgs.contains(where: { (($0["role"] as? String) ?? "") == "assistant" })
            let userTs = convs.append(cid, role: "user", content: askText)   // HORODATAGE (askText = texte relu si porte voix validée)
            // WP3 : SEULE porte d'approbation côté conversation — la confirmation explicite d'Ahadi (texte relu en voix)
            // approuve l'action « Envoi à approuver » affichée au tour précédent de CE fil ; une négation révoque.
            let sendMint: MintOutcome = SendApprovals.shared.noteUserTurn(ctx: execCtx, text: askText)
            Amplitude.track("conversation_message_sent", ["chars": text.count, "light": false])   // AMPLITUDE : métadonnées seules — jamais le contenu
            let greetNow: Bool = NovaSoul.shouldGreet(firstMessage: firstMessage, lastExchange: prevExchange)
            res.sseStart(); res.sse("meta", ["conversation_id": cid, "light": false, "demo": demoOn, "user_ts": userTs, "greet": greetNow])   // « light » reste dans le contrat web, toujours false
            if let tb = j["tab"] as? String, !tb.isEmpty { EnvCache.shared.setTab(tb) }   // onglet courant, si l'interface le transmet

            // 31/10 (CAFU) : MODE ANALYSE CAFU — demande de note CAFU / section GHO / brief de contexte (déclencheurs du skill
            // cafu-note-quality-v2) → recherche obligatoire (Algolia + Tavily) puis Spark 1.3 épinglé au raisonnement maximal,
            // garde de citation et journal (Feat_CafuMode.swift). Réglage « cafu_mode » (défaut true) ; « cafu »: false dans la
            // requête le saute pour un message ; « cafu_test » (test d'acceptation dormant) le force. Le chat ordinaire est inchangé.
            let cafuTest: Bool = (j["cafu_test"] as? Bool) == true
            if !bancTurn, !spoken, !demoOn, (j["cafu"] as? Bool) != false,
               cafuTest || (settings.get("cafu_mode", true) && CafuMode.detect(askText)) {
                self.cafuRun(cid: cid, ask: askText, test: cafuTest, incognito: incognito, chatT0: chatT0, res: res)
                return
            }

            // 1) Contexte dynamique EN PARALLÈLE (mémoire pertinente, documents, rappel des
            //    conversations, projets, skills qui correspondent, tableau de bord des Dots).
            let ctx = ChatCtxBox()
            let g = DispatchGroup()
            let mem: Memory = memory
            let kn: Knowledge = Knowledge.shared
            func job(_ f: @escaping () -> Void) { g.enter(); DispatchQueue.global(qos: .userInitiated).async { f(); g.leave() } }
            // MÉMOIRE SOUVERAINE (24/10) : le bloc mémoire est TOUJOURS recalculé (vecteur de requête déjà
            // en cache si /speculate est passé) pour connaître les faits exacts injectés (provenance) et
            // qu'un fait oublié dans les 15 s du cache spéculatif ne soit jamais servi.
            let prov = MemoryProvBox()
            job { let items: [[String: Any]] = mem.chatItems(query: text); let v: String = Memory.formatBlock(items); ctx.set { $0.mem = v }; prov.setMem(items) }   // VAGUE 2 FIABILITÉ : faits PERTINENTS seulement (seuil de score, Feat_Maintenance) — la puce compte ce qui a été choisi
            if let sp = SpeculativeCache.shared.take(SpeculativeCache.key(text)) {   // contexte déjà pré-calculé par /api/assistant/speculate
                ctx.set { $0.know = sp.knowledge }
            } else {
                job { let v: String = kn.hitsBlock(query: text); ctx.set { $0.know = v } }
            }
            job { let v: String = mem.isOff ? "" : self.recallBlock(excluding: cid); ctx.set { $0.recall = v }; if !v.isEmpty { prov.setRecall(self.recallProvenance(excluding: cid)) } }
            job { let v: String = ProjectMemory.promptBlock(for: text); ctx.set { $0.proj = v } }
            job { let v: String = NovaSkills.relevantBlock(for: text); ctx.set { $0.skills = v } }
            if useTools { job { let v: String = NovaMap.dashboard(); ctx.set { $0.dash = v } } }
            if g.wait(timeout: .now() + 8) == .timedOut {
                _ = BlackBox.record(["tool": "app", "actor": "Nova", "why": "assemblage du contexte : un bloc a dépassé 8 s — le tour part avec les blocs prêts", "ok": false, "effect": "lecture"])
            }
            let c: ChatCtxBox.Snapshot = ctx.snapshot()
            let provOut: [String: Any] = MemoryLedger.provenance(mem: prov.memItems(), profile: mem.profileItems(), recall: prov.recallItems(), incognito: incognito)
            var provSent: Bool = false

            // 2) Prompt : statique (avant cacheMark) puis dynamique.
            let title: String = settings.get("user_title", "Capitaine")
            let autonomie: String = (j["autonomie"] as? String) ?? "total"
            let fullAutoSetting: Bool = settings.get("autorisation_totale", false)   // REVUE-GATE 22/10 : état RÉEL du réglage, lu comme gate() le lit
            var stableParts: [String] = []
            let styleB: String = StyleProfile.promptBlock()
            if !styleB.isEmpty { stableParts.append(styleB) }
            let doct: String = Knowledge.shared.doctrineBlock()
            if !doct.isEmpty { stableParts.append(doct) }
            if useTools { stableParts.append(NovaMap.text + "\nTu es le CHEF D'ORCHESTRE : pour toute demande sur Nova, ses Dots, ses réglages ou ses onglets, agis avec l'outil app (lecture ET modification), puis rends compte.") }
            // 31/10 (audit prompt) : la ligne d'autonomie (ne dépend que du mode et du réglage autorisation_totale) et le texte fixe de la
            // règle de fil passent du suffixe dynamique (jamais en cache) au préfixe stable (en cache) — même contenu, envoyé une fois en cache.
            stableParts.append(NovaSoul.autonomyLine(mode: autonomie, fullAuto: fullAutoSetting))
            stableParts.append(NovaApp.followRule)
            var dyn: [String] = [NovaSoul.openingCue(firstMessage: firstMessage, lastExchange: prevExchange)]
            let depthB: String = NovaApp.depthPrompt((j["depth"] as? Int) ?? 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !depthB.isEmpty { dyn.append(depthB) }
            // 31/10 (Ahadi : « alléger le contexte ») — le suffixe dynamique n'est PAS en cache : il est payé plein tarif à CHAQUE étape
            // d'outil (22 800 caractères mesurés). Chaque bloc est plafonné ; le détail reste accessible par les outils recall/know/skill.
            for (b, cap) in [(c.recall, 2500), (c.know, 1500), (c.proj, 1500), (c.skills, 2500), (c.dash, 1500)] {
                let t: String = NovaApp.clipBlock(b, cap)
                if !t.isEmpty { dyn.append(t) }
            }
            let tempB: String = TemporalStore.chatBlock(query: text, enabled: settings.get(TemporalMemory.settingKey, true))   // CHANTIER 2b : faits dates en vigueur, lecture seule, derriere memoire_temporelle (defaut actif)
            if !tempB.isEmpty { dyn.append(NovaApp.clipBlock(tempB, 1500)) }
            let evB: String = self.recentEventsBlock()   // V5-T (25/10) : Fil direct + Éclats récents, dans le suffixe dynamique de TOUT cerveau (Spark compris)
            if !evB.isEmpty { dyn.append(NovaApp.clipBlock(evB, 1500)) }
            let sysBase: String = Persona.system(title: title, memory: c.mem, voice: spoken, tools: useTools, extra: dyn.joined(separator: "\n\n"), stable: stableParts.joined(separator: "\n\n"))
            // 30/10 (GO 4, dépense) : TAILLE du préfixe envoyé, bloc par bloc (caractères, aucun contenu) — pour réduire ce qui pèse.
            do {
                let stableLen: Int = sysBase.range(of: Persona.cacheMark).map { sysBase.distance(from: sysBase.startIndex, to: $0.lowerBound) } ?? sysBase.count
                let sizes: [String: Any] = ["generated": nowISO(), "systeme_total": sysBase.count, "prefixe_stable": stableLen,
                    "suffixe_dynamique": sysBase.count - stableLen, "style": styleB.count, "doctrine": doct.count,
                    "carte_nova": useTools ? NovaMap.text.count : 0, "memoire": c.mem.count, "rappel": c.recall.count, "savoir": c.know.count,
                    "projet": c.proj.count, "competences": c.skills.count, "tableau_de_bord": c.dash.count, "evenements": evB.count,
                    "outils_schemas": useTools ? String(decoding: jsonData(Tools.nativeSchemas(allowed: nil)), as: UTF8.self).count : 0]
                try? jsonData(sizes).write(to: URL(fileURLWithPath: NSHomeDirectory() + "/spark-local/Nova2/releves/diag/prefixe_tailles.json"))
            }

            // 3) Cerveau du tour (inchangé : démo, verrou, choix par message, rejet annoncé).
            var stepsMax: Int = settings.get("etapes_max_par_demande", 12)   // 31/10 (Ahadi : plafond par demande) — avant : 30 en autonomie totale, 18 sinon (jusqu'à 18 outils, 5 min, ~0,5 $ mesurés)
            let agent = Agent(router: router, tools: tools)
            let demoBrain: String = settings.get("demo_brain", "spark-1.3")   // FIX-DEMO 22/10
            let pref0: String = demoOn ? demoBrain : ((j["brain"] as? String) ?? settings.get("brain", "spark-1.3"))   // FIX-DEMO 22/10 : en mode démo, le cerveau de démo prime ; sinon choix par message, sinon défaut verrouillé
            let brainLock: Bool = settings.get("brains_lock", true)   // LOT4b P-BRAIN : pas de reroutage silencieux vers le local
            let demoExempt: String? = (demoOn && pref0 == demoBrain) ? pref0 : nil   // DIAG2 P1 : exemption « disabled » du seul cerveau de démo, pour ce run
            if let dx = demoExempt, router.disabled.contains(dx) { _ = BlackBox.record(["tool": "app", "actor": "Nova", "why": "mode démo : exemption temporaire de \(dx) pour ce run (présent dans brains_off, laissé intact)", "ok": true, "effect": "lecture"]) }
            let pref: String = pref0   // version Meta : aucun moteur local
            // PLAFOND DE DÉPENSE (Lot B 27/10) : si le coût estimé du jour a atteint le
            // plafond réglé (plafond_cout_jour_usd, 0 = désactivé), le tour part sur le
            // cerveau local et c'est DIT (jamais de reroutage silencieux) + journalisé.
            var prefFinal: String = pref
            let plafondJour: Double = settings.get("plafond_cout_jour_usd", 0.0)
            if plafondJour > 0, !demoOn, pref != "local" {
                let todayUsd: Double = Couts.todayUsd(journal: router.journal.url, settings: settings)
                if todayUsd >= plafondJour {
                    prefFinal = "local"
                    res.sse("brain_rejected", ["id": pref, "label": "Plafond du jour", "reason": "plafond de dépense atteint (\(String(format: "%.2f", todayUsd)) $ estimés aujourd'hui ≥ \(String(format: "%.0f", plafondJour)) $) — bascule sur le cerveau local pour ce tour"])
                    _ = BlackBox.record(["tool": "plafond_cout", "actor": "Nova", "effect": "lecture", "ok": true,
                                         "why": "plafond quotidien atteint — bascule local annoncée",
                                         "result": "aujourdhui≈\(String(format: "%.2f", todayUsd))$ plafond=\(String(format: "%.0f", plafondJour))$ cerveau demandé=\(pref)"])
                }
            }
            if pref != "auto", !pref.isEmpty {   // DIAG2-CERVEAUX : un cerveau nommé inexécutable est DIT avant le run
                if let sp = router.spec(pref) {
                    if sp.kind != .local, sp.keys.resolve(router.runner.keys) == nil {
                        res.sse("brain_rejected", ["id": pref, "label": sp.label, "reason": "sans clé dans le Trousseau — ajoute la clé dans Connexions, ou choisis un autre cerveau"])
                    }
                } else {
                    res.sse("brain_rejected", ["id": pref, "label": pref, "reason": "cerveau inconnu du catalogue (réglage purgé au prochain démarrage)"])
                }
            }
            let mode: String = (j["mode"] as? String) ?? "fast"
            let prefPlanned: String = prefFinal
            let maxTok: Int = (spoken && !useTools) ? 800 : (mode == "deep" ? 32000 : 16000)   // FIX-PLAFOND 21/10 : 16 000 / 32 000 ; 800 seulement pour une réponse parlée SANS outil

            // 4) Historique : budget calculé sur une fenêtre STABLE — la plus petite des cerveaux cloud
            //    de la chaîne ([tiers]/[tiers]/[tiers]), pour que changer de cerveau ou de sélecteur en
            //    cours de fil ne change pas ce que le cerveau reçoit ; seul un cerveau local réduit le
            //    budget. Ce qui ne tient pas est condensé en tête (Conversations.history), jamais coupé.
            let plan0: [BrainSpec] = router.plan(mode: mode, preferred: prefFinal, exempt: demoExempt)
            let servingId: String = plan0.first?.id ?? pref
            let firstKind: BrainKind? = plan0.first?.kind
            let servingLocal: Bool = (firstKind.map { $0 == .local } ?? false) || servingId == "local"
            // 01/11 (chat abouti) : cerveau Meta (Spark 1.3 : 1,25 $ / 4,25 $ par M) → plafonds par demande RELEVÉS (étapes et dépense,
            // voir ChatCaps) : une réponse complète ne s'arrête plus à la 10e étape (~0,40 $ au tarif du cache surfacturé).
            let metaTurn: Bool = ChatCaps.isMeta(router.spec(servingId))
            stepsMax = ChatCaps.steps(settings: settings, meta: metaTurn)
            let winServing: Int = ContextWindow.tokens(for: servingId)
            let winStable: Int = servingLocal ? winServing : min(winServing, ContextWindow.tokens(for: "spark-open-baseten"))
            // 30/10 (GO historique d'Ahadi, dépense) : l'historique verbatim est plafonné (réglage « historique_max_jetons »,
            // 12 000 ; 20 000 en mode approfondi) — avant, jusqu'à 96 000 jetons, soit ~53 % de chaque appel [tiers]. Le reste du
            // fil n'est pas perdu : Conversations.history le condense en tête (résumé du fil + note des échanges écartés).
            let histCap: Int = settings.get("historique_max_jetons_v2", mode == "deep" ? 16000 : 8000)   // 31/10 : 12 000 → 8 000 (rapide), 20 000 → 16 000 (profond)
            let ctxBudget: Int = min(max(4000, histCap), max(4000, ContextBudget.historyTokens(window: winStable, system: sysBase, maxTokens: maxTok, useTools: useTools) - 1500))   // 1 500 : réserve de la règle de fil ajoutée ci-dessous
            let histMain: [ChatMsg] = convs.history(cid, tokenBudget: ctxBudget)
            let sys: String = sysBase + NovaApp.followPrompt(histMain) + NovaApp.liveContextBlock(ecran: j["ecran"] as? String)   // règle de fil + conscience d'environnement mesurée ce tour-ci

            // V4-D (24/10) — VISION MULTIMODALE : images jointes (chemins du dossier Attachments) et captures du Témoin
            // (identifiants du dépôt RAM) → blocs image [tiers] sur le message courant. Si le cerveau qui sert ce tour
            // n'est pas [tiers] (seul multimodal câblé ici), refus HONNÊTE : événement « vision » ok:false + consigne au
            // cerveau de dire qu'il ne voit pas l'image (le texte OCR éventuel reste dans le message).
            var histRun: [ChatMsg] = histMain
            let imgReq: [[String: Any]] = (j["images"] as? [[String: Any]]) ?? []
            if !imgReq.isEmpty {
                var imgBlocks: [[String: Any]] = []; var imgLabels: [String] = []; var imgRefused: [String] = []
                let multimodal: Bool = false   // version Meta : blocs image non câblés pour l'API Meta ici — refus honnête (texte OCR conservé)
                for it in imgReq.prefix(VisionInput.maxImages) {
                    if !multimodal {
                        if let sid = it["id"] as? String { _ = VisionInput.stashedBlock(id: sid) }   // capture consommée : rien ne reste en mémoire
                        continue
                    }
                    let got: (block: [String: Any]?, label: String, error: String)
                    if let p = it["path"] as? String, !p.isEmpty { got = VisionInput.fileBlock(path: p) }
                    else if let sid = it["id"] as? String, !sid.isEmpty { got = VisionInput.stashedBlock(id: sid) }
                    else { continue }
                    if let b = got.block { imgBlocks.append(b); imgLabels.append(got.label) } else { imgRefused.append(got.label + " : " + got.error) }
                }
                if imgReq.count > VisionInput.maxImages { imgRefused.append("\(imgReq.count - VisionInput.maxImages) image(s) au-delà de \(VisionInput.maxImages) par message — non jointes") }
                if let li = histRun.lastIndex(where: { $0.role == "user" }) {
                    if multimodal && !imgBlocks.isEmpty {
                        histRun[li].content += "\n\n[MOTEUR NOVA] \(imgBlocks.count) image(s) jointe(s) en vision native (" + imgLabels.joined(separator: ", ") + "). Si tu ne les vois pas, dis-le franchement — n'invente jamais leur contenu."
                        let tb: [String: Any] = ["type": "text", "text": histRun[li].content]
                        histRun[li].blocks = imgBlocks + [tb]
                    } else if !multimodal {
                        histRun[li].content += "\n\n[MOTEUR NOVA] Ahadi a joint \(min(imgReq.count, VisionInput.maxImages)) image(s), mais le cerveau de ce tour ne voit pas les images : dis-le en une phrase, n'en décris jamais le contenu ; seul le texte reconnu (OCR) éventuellement fourni ci-dessus est utilisable."
                    }
                }
                let vinfo: [String: Any] = ["ok": multimodal && !imgBlocks.isEmpty, "multimodal": multimodal, "sent": imgBlocks.count, "labels": imgLabels, "refused": imgRefused, "brain": servingId,
                                            "reason": multimodal ? (imgBlocks.isEmpty ? "aucune image exploitable" : "") : "le cerveau de ce tour (" + servingId + ") n'est pas branché en vision ici — le texte OCR éventuel reste joint"]
                res.sse("vision", vinfo)
                _ = BlackBox.record(["tool": "vision", "actor": "Nova", "why": "images du message : \(imgBlocks.count) envoyée(s) à \(servingId), \(imgRefused.count) refusée(s)" + (multimodal ? "" : " — cerveau non multimodal"), "ok": multimodal && !imgBlocks.isEmpty, "effect": "lecture"])
            }

            // 27/10 : tâche précédente non livrée dans ce fil → note moteur (jamais d'oubli silencieux).
            if let note = ChatTasks.note(for: cid), let li = histRun.lastIndex(where: { $0.role == "user" }) {
                histRun[li].content += note
            }
            // 01/11 (chat abouti) : « envoie » / « go » d'Ahadi a APPROUVÉ l'envoi affiché → le MOTEUR l'exécute tout de suite (mêmes gardes
            // que l'outil : politique, Confiance, approbation liée à l'instantané) et le cerveau ne fait que rapporter le résultat. Avant :
            // tout dépendait d'un appel mail_envoyer du cerveau ; « Je l'envoie. » sans appel laissait le tour muet, l'envoi jamais fait.
            var engineSendOut: String? = nil
            if case .minted(_, let draftId) = sendMint, EngineSend.directAllowed(policy: Tools.policy(for: "mail_envoyer"),
                                                                                 verdict: Trust.verdict(tool: "mail_envoyer", arg: draftId, actor: "Nova", why: askText).action) {
                let sid: String = String(UUID().uuidString.prefix(8)).lowercased()
                res.sse("step", ["id": sid, "index": 1, "tool": "mail_envoyer", "arg": draftId, "state": "run", "ts": nowISO()])
                let t0s: Date = Date()
                let out: String = tools.run("mail_envoyer", draftId, why: askText, actor: "Nova")
                let failedS: Bool = Tools.toolFailed("mail_envoyer", out)
                res.sse("step", ["id": sid, "index": 1, "tool": "mail_envoyer", "arg": draftId, "state": failedS ? "err" : "ok", "ms": Int(Date().timeIntervalSince(t0s) * 1000), "ts": nowISO()])
                res.sse("tool", ["name": "mail_envoyer", "input": draftId, "output": String(out.prefix(600))])
                engineSendOut = out
            }
            if let sn = (engineSendOut.map { EngineSend.reportNote(result: $0) } ?? sendMint.engineNote), let li = histRun.lastIndex(where: { $0.role == "user" }) { histRun[li].content += sn }   // WP3 : note moteur, jamais une autorisation en soi

            // 5) Run unique.
            var answer = ""; var brainLabel = ""; var lastCk = Date.distantPast; var toolNotes: [String] = []; var missionSteps: [MissionGate.Step] = []
            var firstDeltaAt: Date? = nil   // LATENCE RÉELLE (27/10) : premier fragment du tour
            let dedup = StreamDedup()   // 27/10 : phrases de reprise répétées après chaque outil — émises une seule fois
            var afterTool: Bool = false   // 25/10 : frontière d'outil — le texte suivant part en nouveau paragraphe (fini « …fin.Je lance… »)
            var runFailure = ""   // DIAG2-CONTEXTE P-CTX-1 : première erreur vue — nomme la cause d'un tour sans réponse
            let ledger = ChatLedgerBox()
            let factSeen = FactGate.Seen()   // 01/11 : sorties d'outils du tour, pour la vérification des sources (VerifFaits.swift)
            if let so = engineSendOut { toolNotes.append("mail_envoyer"); missionSteps.append(MissionGate.Step(name: "mail_envoyer", failed: Tools.toolFailed("mail_envoyer", so))); ledger.add("mail_envoyer", "", so) }
            // Contrat agent (24/10) : quand Agent.run expose `onLedger:`, passer `onLedger: ledgerSink`
            // (entre `cancel:` et `onEvent:`). En attendant, le grand livre est reconstruit
            // à l'identique depuis les événements .step/.tool ; s'il arrive par onLedger, il fait foi.
            let ledgerSink: ([[String: Any]]) -> Void = { l in ledger.setFromAgent(l) }
            // 27/10 (audit : « Je lis ta pièce jointe… je lis ta pièce jointe… ») : les notes
            // d'étape consécutives identiques sont compressées avant l'affichage d'attente.
            let ckp = { (force: Bool) in if force || Date().timeIntervalSince(lastCk) > 3 { lastCk = Date(); var notes: [String] = []; for n in toolNotes.suffix(6) where notes.last != n { notes.append(n) }; let body = answer.isEmpty ? "⏳ en cours… " + notes.suffix(4).joined(separator: " · ") : answer; self.convs.checkpoint(cid, content: body, brain: brainLabel) } }
            let onEv: (BrainEvent) -> Void = { ev in
                switch ev {
                case .start(let id, let l): brainLabel = l; res.sse("brain", ["id": id, "label": l])
                case .draftReset: answer = ""; dedup.reset(); res.sse("reset", ["scope": "draft"])   // VÉRITÉ-3 : la génération remplacée quitte aussi l'écran
                case .delta(let t):
                    if firstDeltaAt == nil { firstDeltaAt = Date() }   // LATENCE RÉELLE (27/10) : premier mot, mesuré par le moteur
                    if afterTool { afterTool = false; if !answer.isEmpty && !answer.hasSuffix("\n") { answer += "\n\n" } }
                    let emit: String = dedup.push(t)
                    answer += emit; if !emit.isEmpty { res.sse("delta", ["t": emit]) }; ckp(false)
                case .failover(let f, let t, let r, _): res.sse("failover", ["from": f, "to": t, "reason": r])
                case .tool(let n, let i, let o): afterTool = true; toolNotes.append(n); missionSteps.append(MissionGate.Step(name: n, failed: Tools.toolFailed(n, o))); ledger.add(n, i, o); factSeen.add(o); ckp(true); res.sse("tool", ["name": n, "input": String(i.prefix(300)), "output": String(o.prefix(bancTurn ? 12000 : 600))])   // 31/10 : sortie complète pour les correcteurs du banc agent
                case .step(let k, let info):
                    if k == "step", let stt = info["state"] as? String, stt == "ok" || stt == "err" { ledger.noteState(stt == "ok") }
                    if k == "steer", let stx = info["text"] as? String, !stx.isEmpty { ledger.noteSteer(stx) }
                    res.sse(k, info)   // LOT M : « step » (plan visible) et « confirm » (carte de confirmation)
                case .usage(let i, let o): res.sse("usage", ["in": i, "out": o])
                case .error(let m): if runFailure.isEmpty { runFailure = m }; res.sse("error", ["message": m])
                case .done(let id, let l):
                    if !provSent { provSent = true; res.sse("memory", provOut) }   // MÉMOIRE SOUVERAINE : provenance du tour, juste avant « done »
                    // LATENCE RÉELLE (27/10) : chiffres mesurés sur CE tour (premier mot /
                    // total moteur) — l'ancienne métrique dérivée des horodatages de cartes
                    // (jusqu'à ~10 h) ne voulait rien dire.
                    let ttftMs: Int = firstDeltaAt.map { Int($0.timeIntervalSince(chatT0) * 1000) } ?? -1
                    res.sse("done", ["brain": id, "label": l, "light": false,
                                     "ttft_ms": ttftMs, "total_ms": Int(Date().timeIntervalSince(chatT0) * 1000),
                                     "cout_usd": (LLMSpend.turnSpent() * 10000).rounded() / 10000])   // 31/10 : coût réel de la demande (tous fournisseurs comptés)
                default: break   // robustesse : un futur cas de BrainEvent (couche agent) ne casse pas la compilation
                }
            }
            // 31/10 (Ahadi : « plafond par demande ») — au-delà de « plafond_par_demande_usd » (0,40 $ par défaut, 0 = sans plafond),
            // la demande s'arrête à l'étape suivante et le DIT ; « continue » relance une nouvelle demande avec son propre plafond.
            // 01/11 (chat abouti) : plafond propre aux cerveaux Meta (ChatCaps.perTurnUSD) ; une attente d'approbation n'est JAMAIS coupée
            // par le plafond (seul « Stop » l'arrête) — sinon le clic « Approuver » arrivait sur une demande déjà abandonnée.
            let capTurn: Double = ChatCaps.perTurnUSD(settings: settings, meta: metaTurn)
            var capHit: Bool = false
            let userStop: () -> Bool = { Tools.isStopped(cid, since: chatT0) }
            let stopCheck: () -> Bool = {
                if userStop() { return true }
                if Tools.awaitingApproval() { return false }
                if capTurn > 0 && LLMSpend.turnSpent() >= capTurn { capHit = true; return true }
                return false
            }
            // changer de conversation NE coupe pas la tâche : seul « Stop » (ou un nouveau message) l'arrête
            _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: maxTok, useTools: useTools, maxSteps: stepsMax, ordered: true, cancel: stopCheck, onLedger: ledgerSink, steerKey: cid, onEvent: onEv)   // A1 : message du Capitaine = run ordonné, piste entière

            steerClosed = true
            let steerLeft: [String] = SteerQueue.shared.end(cid)   // V4-D : précisions arrivées après la dernière étape d'outil — rendues au client, jamais perdues
            if !steerLeft.isEmpty {
                let su: [String: Any] = ["texts": steerLeft, "note": "arrivées après la dernière étape : à envoyer comme message"]
                res.sse("steer_unused", su)
            }
            // 27/10 : vider le tampon de dédoublonnage (la fin de phrase part à l'écran et au checkpoint).
            let dedupTail: String = dedup.flush()
            if !dedupTail.isEmpty { answer += dedupTail; res.sse("delta", ["t": dedupTail]) }

            // FILET DE SORTIE (27/10, audit qualité G2/G3) : annonce sans livraison
            // (« Je lance… je te reviens ») → UNE continuation moteur immédiate,
            // jamais une deuxième, jamais si l'utilisateur a arrêté le tour.
            if !stopCheck() && DeliveryGate.needsContinuation(answer: answer, ask: askText, toolCount: toolNotes.count) {
                _ = BlackBox.record(["tool": "filet_sortie", "actor": "Nova", "effect": "lecture", "ok": true,
                                     "why": "tour terminé sur une annonce sans livraison — continuation moteur unique",
                                     "result": String(answer.prefix(120))])
                histRun.append(ChatMsg("assistant", answer))
                histRun.append(ChatMsg("user", DeliveryGate.continuationNote))
                if !answer.hasSuffix("\n") { answer += "\n\n" }
                dedup.reset()
                // 31/10 (Ahadi : « débarrasse-moi des choix qui pointent toujours vers [tiers] ») : la continuation reste sur le cerveau qui a répondu (avant : forcée sur [tiers]).
                _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: maxTok, useTools: useTools, maxSteps: stepsMax, ordered: true, cancel: stopCheck, onLedger: ledgerSink, steerKey: cid, onEvent: onEv)
                let tail2: String = dedup.flush()
                if !tail2.isEmpty { answer += tail2; res.sse("delta", ["t": tail2]) }
            }

            // 29/10 (chantier 3) : PORTE DE MISSION — abandon prématuré ou affirmation sans preuve → une passe de continuation (Feat_Mission.swift).
            if !stopCheck() && !spoken, let mnote: String = MissionGate.check(answer: answer, steps: missionSteps) {
                histRun.append(ChatMsg("assistant", answer))
                histRun.append(ChatMsg("user", mnote))
                if !answer.hasSuffix("\n") { answer += "\n\n" }
                dedup.reset()
                let missionPrev: String = answer
                res.sse("reset", ["scope": "draft"]); answer = ""   // la réponse mise à jour REMPLACE la version abandonnée
                _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: maxTok, useTools: useTools, maxSteps: min(stepsMax, 12), ordered: true, cancel: stopCheck, onLedger: ledgerSink, steerKey: cid, onEvent: onEv)
                let tailM: String = dedup.flush()
                if !tailM.isEmpty { answer += tailM; res.sse("delta", ["t": tailM]) }
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 { answer = missionPrev; res.sse("final", ["t": missionPrev]) }   // passe vide → la version précédente revient
            }

            // 01/11 (Ahadi : « le moins hallucinant ») : VÉRIFICATION DES SOURCES hors CAFU — une URL citée qu'aucun outil du tour n'a
            // renvoyée (ni le fil, ni le prompt système) → UNE passe de vérification si les outils sont là ; le reste est marqué
            // [[NON CONFIRMÉ]] juste avant la finition. Réglage « verif_faits » (défaut true). Zéro appel quand la réponse est propre.
            let factAllowed: () -> [String] = { factSeen.all + histRun.map { $0.content } + [sys] }
            if !stopCheck() && !spoken && FactGate.enabled(settings),
               let fnote: String = FactGate.check(answer: answer, allowed: factAllowed(), toolsAvailable: useTools) {
                histRun.append(ChatMsg("assistant", answer))
                histRun.append(ChatMsg("user", fnote))
                if !answer.hasSuffix("\n") { answer += "\n\n" }
                dedup.reset()
                let factPrev: String = answer
                res.sse("reset", ["scope": "draft"]); answer = ""
                _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: maxTok, useTools: useTools, maxSteps: min(stepsMax, 6), ordered: true, cancel: stopCheck, onLedger: ledgerSink, steerKey: cid, onEvent: onEv)
                let tailF: String = dedup.flush()
                if !tailF.isEmpty { answer += tailF; res.sse("delta", ["t": tailF]) }
                if answer.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 { answer = factPrev; res.sse("final", ["t": factPrev]) }
            }
            if !spoken && FactGate.enabled(settings) {
                let marked: String = FactGate.annotate(answer: answer, allowed: factAllowed())
                if marked != answer { answer = marked; res.sse("final", ["t": marked]) }
            }

            // 29/10 (Ahadi) : CONTRÔLE QUALITÉ — [tiers] relit les réponses de fond ; un manque ou une erreur concrète → un complément, une fois.
            if !stopCheck() && AutoEval.eligible(answer: answer, simple: prefPlanned != prefFinal, spoken: spoken, settings: settings),
               let qnote: String = AutoEval.review(router: router, ask: askText, answer: answer) {
                _ = BlackBox.record(["tool": "controle_qualite", "actor": "Nova", "effect": "lecture", "ok": true,
                                     "why": "contrôle qualité : complément demandé", "result": String(qnote.prefix(200))])
                histRun.append(ChatMsg("assistant", answer))
                histRun.append(ChatMsg("user", qnote))
                if !answer.hasSuffix("\n") { answer += "\n\n" }
                dedup.reset()
                _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: maxTok, useTools: useTools, maxSteps: min(stepsMax, 8), ordered: true, cancel: stopCheck, onLedger: ledgerSink, steerKey: cid, onEvent: onEv)
                let tail3: String = dedup.flush()
                if !tail3.isEmpty { answer += tail3; res.sse("delta", ["t": tail3]) }
            }
            // 01/11 (chat abouti) : le tour finit ENCORE sur une annonce après la continuation unique → l'état réel est dit (anti-silence),
            // jamais une seconde continuation (anti-boucle). Un envoi exécuté par le moteur rapporte toujours son résultat.
            if !capHit, !userStop(), !spoken, DeliveryGate.endsOnPromise(answer) {
                answer += DeliveryGate.unfinishedNote; res.sse("delta", ["t": DeliveryGate.unfinishedNote])
                _ = BlackBox.record(["tool": "filet_sortie", "actor": "Nova", "effect": "lecture", "ok": false, "why": "annonce finale non suivie d'exécution — état dit à l'écran", "result": String(answer.suffix(160))])
            }
            if let so = engineSendOut, let line = EngineSend.missingReport(answer: answer, result: so) {
                answer += line; res.sse("delta", ["t": line])
            }
            if capHit {
                // 01/11 (chat abouti) : plafond VRAIMENT atteint → Nova CONCLUT au lieu de couper : une passe de rédaction, sans outil,
                // à partir de ce qui a été rassemblé (une seule, bornée par ChatCaps.finishAllowed ; seul « Stop » l'interrompt). Le
                // plafond mensuel dur reste appliqué par la réservation avant envoi (LLMSpend.preflight).
                var concluded: Bool = false
                if !userStop(), ChatCaps.finishAllowed(spent: LLMSpend.turnSpent(), cap: capTurn) {
                    histRun.append(ChatMsg("assistant", answer.isEmpty ? "(étapes en cours)" : answer))
                    histRun.append(ChatMsg("user", ChatCaps.finishNote(tools: toolNotes)))
                    if !answer.isEmpty && !answer.hasSuffix("\n") { answer += "\n\n" }
                    dedup.reset()
                    let before: Int = answer.count
                    _ = agent.run(messages: histRun, system: sys, mode: mode, preferred: prefFinal, exemptBrain: demoExempt, maxTokens: min(maxTok, 6000), useTools: false, maxSteps: 0, ordered: true, cancel: userStop, onLedger: ledgerSink, steerKey: nil, onEvent: onEv)
                    let tailF: String = dedup.flush()
                    if !tailF.isEmpty { answer += tailF; res.sse("delta", ["t": tailF]) }
                    concluded = answer.count - before >= 40
                }
                let spent: String = String(format: "%.2f", LLMSpend.turnSpent()).replacingOccurrences(of: ".", with: ",")
                let capS: String = String(format: "%.2f", capTurn).replacingOccurrences(of: ".", with: ",")
                let note: String = concluded
                    ? "\n\n⏸ Plafond par demande atteint (" + spent + " $ sur " + capS + " $) : réponse conclue avec ce qui était rassemblé. Dis « continue » pour approfondir."
                    : "\n\n⏸ Plafond par demande atteint (" + spent + " $ sur " + capS + " $) : je me suis arrêté ici. Dis « continue » pour que je poursuive."
                answer += note; res.sse("delta", ["t": note])
                _ = BlackBox.record(["tool": "plafond_demande", "actor": "Nova", "effect": "lecture", "ok": true, "why": "plafond par demande atteint" + (concluded ? " — réponse conclue" : ""), "result": spent + " $"])
            }

            // WP3 : toute demande d'envoi née dans ce tour est AFFICHÉE par le moteur (carte exacte : destinataires,
            // expéditeur, objet, corps, pièces jointes, empreinte) — c'est elle que le « envoie » suivant approuve.
            let sendCards: String = SendApprovals.shared.cardsToDisplay(ctx: execCtx)
            if !sendCards.isEmpty { answer += sendCards; res.sse("delta", ["t": sendCards]) }

            // 6) Checkpoint final GARANTI (+ grand livre), horodatage, mémoire en arrière-plan.
            let ledgerFinal: [[String: Any]] = ledger.snapshot()
            let answerClean: String = Finition.polish(NovaApp.dedupeNarr(answer))   // 29/10 : BLUF toujours en tête, annonces d'étape retirées (Feat_Finition.swift)   // 25/10 : phrase de reprise répétée après un outil retirée
            let finalText: String = spoken ? Persona.stripBiChannel(answerClean) : answerClean
            var finalTs: String? = nil
            if !answer.isEmpty { finalTs = convs.checkpoint(cid, content: finalText, brain: brainLabel, final: true, tools: ledgerFinal) }
            if !answer.isEmpty && !internalTurn && !Tools.isStopped(cid, since: chatT0) {   // 01/11 : réponse finie hors de vue (fenêtre inactive ou autre conversation) → notification
                _ = AttentionNotif.responseDone(cid: cid, ask: text, excerpt: finalText, durationS: Date().timeIntervalSince(chatT0))
            }
            if !answer.isEmpty && !spoken && finalText != answer { res.sse("final", ["t": finalText]) }   // 29/10 : l'écran montre la version finie (sans annonces d'étape)
            else if !toolNotes.isEmpty { finalTs = convs.checkpoint(cid, content: "(interrompu avant la réponse — outils lancés : " + toolNotes.suffix(6).joined(separator: ", ") + ")", brain: brainLabel, final: true, tools: ledgerFinal) }
            else {
                // DIAG2-CONTEXTE P-CTX-1 : un tour commencé laisse toujours une trace finale et explicite ; la cause est celle que la route a vue.
                let cause: String = stopCheck() ? "arrêté par l'utilisateur avant le premier mot"
                    : (!runFailure.isEmpty ? "échec du run : " + String(runFailure.prefix(300))
                       : "le run s'est terminé sans produire de texte")
                finalTs = convs.checkpoint(cid, content: "(sans réponse — " + cause + ")", brain: brainLabel, final: true)
            }
            // 27/10 : registre des tâches — une vraie réponse efface l'attente ; un échec (hors arrêt
            // volontaire) la consigne pour reprise explicite au prochain tour de ce fil.
            if !finalText.isEmpty { ChatTasks.clear(cid) }
            else if !stopCheck() { ChatTasks.register(cid: cid, ask: askText, cause: runFailure.isEmpty ? "tour terminé sans réponse" : String(runFailure.prefix(200))) }
            if finalTs != nil { _ = convs.attachMemory(cid, provOut) }   // MÉMOIRE SOUVERAINE : provenance persistée sur la réponse
            if !provSent { provSent = true; res.sse("memory", provOut) }   // run sans « done » : la provenance est dite quand même
            Amplitude.track("conversation_message_received", ["ok": finalTs != nil, "chars": answer.count])   // AMPLITUDE : compteurs seuls
            if let t = finalTs { res.sse("stamp", ["assistant_ts": t, "user_ts": userTs]) }   // HORODATAGE : ts STOCKÉS des deux bulles
            if !finalText.isEmpty && !incognito {   // MÉMOIRE SOUVERAINE : « Hors mémoire » = le distillateur ne tourne pas
                let convTitle: String = (convs.get(cid)?["title"] as? String) ?? ""
                MemoryDistiller.schedule(router: router, memory: memory, user: askText, assistant: finalText, title: convTitle, tools: toolNotes, conversationId: cid)   // jamais bloquant
            }
        }
    }
}


extension NovaApp {
    /// 31/10 : bloc de contexte plafonné (coupé proprement à la ligne), « … » quand il a été raccourci.
    static func clipBlock(_ s: String, _ cap: Int) -> String {
        let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > cap else { return t }
        var cut: String = String(t.prefix(cap))
        if let nl = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: nl) > cap / 2 { cut = String(cut[..<nl]) }
        return cut + "\n…(bloc raccourci — le détail reste accessible par les outils)"
    }
}
