import Foundation
// Point d'entrée unique des fonctions « Nova Plus » (chacune dans son fichier Feat_*.swift). Appelé par extraRoutes().
// VAGUE 2 FIABILITÉ (24/10) : relu — ce point d'entrée n'enregistre que des routes ; aucun moteur simulé n'y démarre.
// Les moteurs « NOVA XXII » (états inventés) sont coupés dans NovaXXIIBridge.swift (enabled = false, code conservé).
extension NovaApp {
    func novaPlusRoutes() {
        droitsRoutes()        // Feat_Droits.swift
        dotCareRoutes()       // Feat_DotCare.swift
        maintenanceRoutes()   // Feat_Maintenance.swift
        dailyRoutes()         // Feat_Daily.swift
        searchUndoRoutes()    // Feat_Search.swift
        innovRoutes()         // Feat_Innov.swift
        mailApiRoutes()       // Feat_MailAPI.swift (Outlook/Teams bureau, lecture locale)
        projectsRoutes()      // Feat_Projects.swift
        sendQueueRoutes()     // Feat_SendQueue.swift
        phoneRoutes()         // Feat_Phone.swift
        wakeRoutes()          // Feat_Wake.swift
        voixLocaleRoutes()    // 25/10 : Feat_VoixLocale.swift — /api/voix/locale, /api/voix/niveau (lip-sync compagnon)
        sourcesRoutes()       // V5-V (25/10) : Feat_Sources.swift — « Sources de Nova » (/api/sources, /toggle, /add, /remove, /scan ; lecture seule)
    }
}
