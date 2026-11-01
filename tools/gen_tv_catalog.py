# Générateur du catalogue TV (vague 3) : relit les playlists iptv-org téléchargées dans /tmp/iptv3 (candidates.json produit par le parseur), applique la sélection vérifiée et régénère tv-catalog.json + Sources/NovaCore/TVCatalog.swift.
import json

d = json.load(open('/tmp/iptv3/candidates.json'))
def src(cc, sub):
    for e in d:
        if e['cc'] == cc and sub.lower() in e['name'].lower(): return e['url'], e['logo']
    raise SystemExit(f"introuvable: {cc} {sub}")

PAYS = {'bf':'Burkina Faso','ci':"Côte d'Ivoire",'sn':'Sénégal','ml':'Mali','ne':'Niger','tg':'Togo','bj':'Bénin','cm':'Cameroun','gn':'Guinée','cg':'Congo','cd':'RD Congo','fr':'International'}
E = []  # (nom, cc, cats, (cc_src, substr) ou url explicite, logo explicite ou None, niveau)
def A(nom, cc, cats, s, logo=None): E.append((nom, cc, cats, s, logo, 'segment'))
def B(nom, cc, cats, s, logo=None): E.append((nom, cc, cats, s, logo, 'candidat'))

# ── Tier A : prouvées de bout en bout (manifeste + variante + segment), 20/10/2026 ──
A('7 Info','ci',['Afrique','Infos'],('ci','7 Info'))
A('Reflet TV','ci',['Afrique'],('ci','Reflet TV'))
A('Ivoire Channel','ci',['Afrique','Musique'],('ci','Ivoire Channel'))
A('Trace Ivoire','ci',['Afrique','Musique'],('ci','Trace Ivoire'))
A('Serie Max','ci',['Afrique'],('ci','Serie Max'))
A('Afroculture TV','ci',['Afrique'],('ci','Afroculture'))
A('Champion TV','ci',['Afrique'],('ci','Champion TV'))
A('RTVC','ci',['Afrique'],('ci','RTVC'))
A('A2i TV','sn',['Afrique'],('sn','A2i TV'))
A('GMS TV','sn',['Afrique'],('sn','GMS TV'))
A('A2i Music','sn',['Afrique','Musique'],('sn','A2i Music'))
A('Louga TV','sn',['Afrique'],('sn','Louga TV'))
A('SenJeunes TV','sn',['Afrique','Jeunesse'],('sn','SenJeunes'))
A('D3 TV','ml',['Afrique'],('ml','D3 TV'))
A('Télé Sahel','ne',['Afrique'],('ne','Tele Sahel'))
A('Tal TV','ne',['Afrique'],('ne','Tal TV'))
A('NW Info','tg',['Afrique','Infos'],'https://hls.newworldtv.com/nw-info/video/live.m3u8')
A('NW Info 2','tg',['Afrique','Infos'],('tg','NW Info 2'))
A('NW Économie','tg',['Afrique','Infos'],('tg','NW Economie'))
A('NW Magazine','tg',['Afrique'],('tg','NW Magazine'))
A('Télévision Espoir 47','tg',['Afrique'],('tg','Television Espoir'))
A('RT JVA','tg',['Afrique'],('tg','RT JVA'))
A('TVC Bénin','bj',['Afrique'],('bj','TVC Benin'))
A('Eden TV','bj',['Afrique'],('bj','Eden TV'))
A('Espace TV','gn',['Afrique','Infos'],('gn','Espace TV'))
A('Afrik Info TV','gn',['Afrique','Infos'],('gn','Afrik Info'))
A('Kalac TV','gn',['Afrique'],'https://edge13.vedge.infomaniak.com/livecast/ik:kalactv/chunklist_w280736538.m3u8')
A('DRTV International','cg',['Afrique'],('cg','DRTV'))
A('Esaïe 45 Télé','cg',['Afrique'],('cg','Esaie 45'))
A('Baraka Télévision','cd',['Afrique','Infos'],('cd','Baraka'))
A('EVI TV','cd',['Afrique'],('cd','EVI TV'))
A('Lollywood HD','cd',['Afrique'],('cd','Lollywood'))
A('For You TV','cm',['Afrique','Infos'],('cm','For You TV'))
A('Panafrican Media TV','cm',['Afrique','Infos'],('cm','Panafrican Media'))
A('France 24','fr',['Monde','Infos'],'https://live.france24.com/hls/live/2037179-b/F24_FR_HI_HLS/master_5000.m3u8','https://i.imgur.com/u8N6uoj.png')
A('Africanews FR','fr',['Monde','Infos'],'https://cdn-euronews.akamaized.net/live/eds/africanews-fr/25050/index.m3u8','https://i.imgur.com/5UxU4zc.png')
A('Euronews FR','fr',['Monde','Infos'],('fr','Euronews French'))
A('FIFA+ Français','fr',['Monde','Sport'],('fr','FIFA+'))
A('Trace Africa','fr',['Monde','Musique'],('fr','Trace Africa'))
A('Trace Afrikora','fr',['Monde','Musique'],('fr','Trace Afrikora'))
A('Trace Urban','fr',['Monde','Musique'],('fr','Trace Urban (1080p)'))
A('Trace Kitoko','fr',['Monde','Musique'],('fr','Trace Kitoko'))
A('Trace Mboa','fr',['Monde','Musique'],('fr','Trace Mboa'))
A('Trace Gospel','fr',['Monde','Musique'],('fr','Trace Gospel'))
A('Trace Naija','fr',['Monde','Musique'],('fr','Trace Naija'))
A('Trace Sport Stars','fr',['Monde','Sport'],('fr','Trace Sport Stars'))
# ── Tier B : officielles iptv-org, non confirmables depuis le bac à sable (403 proxy/géo ou session CDN) — le moteur re-teste en direct depuis le Mac ──
B('RTB','bf',['Burkina','Afrique'],('bf','RTB (360p)'))
B('RTB 3','bf',['Burkina','Afrique'],('bf','RTB 3'))
B('Canal 3 Burkina','bf',['Burkina','Afrique'],('bf','Canal 3 (Burkina'))
B('ORTM 1','ml',['Afrique'],('ml','ORTM 1'))
B('Dounia TV','ne',['Afrique'],('ne','Dounia TV'))
B('Saraounia TV','ne',['Afrique'],('ne','Saraounia'))
B('CRTV','cm',['Afrique'],('cm','CRTV (Cameroon)'))
B('CRTV News','cm',['Afrique','Infos'],('cm','CRTV News'))
B('CRTV Sports','cm',['Afrique','Sport'],('cm','CRTV Sports'))
B('Afrique Média','cm',['Afrique','Infos'],('cm','Afrique Media'))
B('ADO TV','bj',['Afrique','Jeunesse'],('bj','ADO TV'))
B('ORTB TV','bj',['Afrique'],'https://strhls.streamakaci.tv/ortb/ortb1-multi/playlist.m3u8')
B("NTV Côte d'Ivoire",'ci',['Afrique'],('ci','NTV (Ivory'))
B('Miracle TV+','ci',['Afrique'],('ci','Miracle TV+'))
B('TV5Monde Info','fr',['Monde','Infos'],'https://ott.tv5monde.com/Content/HLS/Live/channel(info)/variant.m3u8','https://i.imgur.com/AJx5Fy2.png')
B('TiVi5 Monde','fr',['Monde','Jeunesse'],'https://ott.tv5monde.com/Content/HLS/Live/channel(tivi5)/variant.m3u8','https://i.imgur.com/fVVKpmk.png')
B('Africa 24','fr',['Afrique','Infos'],('fr','Africa 24 (1080p)'))
B('Africa 24 Sport','fr',['Afrique','Sport'],('fr','Africa 24 Sport'))
B('DBM TV','fr',['Monde','Musique'],('fr','DBM TV'))

out = []
for nom, cc, cats, s, logo, niv in E:
    if isinstance(s, tuple): url, lg = src(*s)
    else: url, lg = s, ''
    out.append({'name': nom, 'cc': cc, 'pays': PAYS[cc], 'cats': cats, 'url': url, 'logo': logo if logo is not None else lg, 'verified': niv})
cat = {'generated': '2026-10-20', 'source': 'iptv-org (GitHub) — playlists pays + index ; tests réels manifeste+variante+segment du 20/10/2026',
       'note': 'verified=segment : chaîne prouvée de bout en bout au test. verified=candidat : chaîne officielle iptv-org non confirmable depuis le bac à sable de test (403 proxy/géo ou session CDN) — le moteur Nova la re-teste en direct depuis le Mac à chaque appel et ne la sert que si elle répond.',
       'channels': out}
json.dump(cat, open('/home/hatch/workspace/nova-rebuild/nova2/tv-catalog.json', 'w'), ensure_ascii=False, indent=1)
na = sum(1 for c in out if c['verified'] == 'segment'); nb = len(out) - na
print(f"catalogue : {len(out)} chaînes ({na} prouvées, {nb} candidates)")

js = json.dumps(cat, ensure_ascii=False)
assert '"""#' not in js
swift = '''import Foundation

/// Catalogue TV Nova — vague 3 (20/10/2026), généré par tools/gen_tv_catalog.py depuis tv-catalog.json.
/// Source : iptv-org (GitHub), référence libre et légale. Chaque chaîne a été testée réellement
/// (manifeste HLS + variante + segment média) le 20/10/2026 : « segment » = prouvée de bout en bout ;
/// « candidat » = officielle iptv-org non confirmable depuis le bac à sable de test (403 proxy/géo
/// ou session CDN Infomaniak) — le moteur la re-teste en direct à chaque appel (test segment inclus)
/// et ne la sert que si elle répond depuis le Mac. Aucune chaîne morte n'est jamais affichée.
public enum TVCatalog {
    private static let json = #"""
''' + js + '''
"""#
    public static let entries: [[String: Any]] = {
        guard let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ch = o["channels"] as? [[String: Any]] else { return [] }
        return ch
    }()
    public static func isCatalogKey(_ k: String) -> Bool { ["afrique", "monde", "infos", "sport", "musique", "jeunesse", "tout"].contains(k) }
    private static func shape(_ e: [String: Any]) -> [String: Any] {
        ["name": e["name"] ?? "", "logo": e["logo"] ?? "", "group": e["pays"] ?? "", "pays": e["pays"] ?? "",
         "cc": e["cc"] ?? "", "cats": e["cats"] ?? [String](), "url": e["url"] ?? "", "verified": e["verified"] ?? ""]
    }
    public static func items(forKey k: String) -> [[String: Any]] {
        let cat = ["afrique": "Afrique", "monde": "Monde", "infos": "Infos", "sport": "Sport", "musique": "Musique", "jeunesse": "Jeunesse"][k]
        return entries.filter { cat == nil || (($0["cats"] as? [String]) ?? []).contains(cat!) }.map(shape)
    }
    public static func pins(forCountry cc: String) -> [[String: Any]] {
        entries.filter { ($0["cc"] as? String) == cc }.map(shape)
    }
}
'''
open('/home/hatch/workspace/nova-rebuild/nova2/Sources/NovaCore/TVCatalog.swift', 'w').write(swift)
print("TVCatalog.swift :", len(swift), "caractères")
