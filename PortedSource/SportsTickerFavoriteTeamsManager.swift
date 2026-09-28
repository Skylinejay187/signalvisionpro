import Foundation
import SwiftUI

// v778: Step 4 architecture migration.
// Owns Sports ticker generation and favorite-team enrichment so SportsLiveZoneModel
// can keep orchestration/state only. Logic intentionally mirrors v777 output.
// vBRDC091: team lookups/ticker construction stay off MainActor until the owning model publishes the result.
struct SportsTickerFavoriteTeamsManager {
    static let shared = SportsTickerFavoriteTeamsManager()

    func favoriteTeamCards(from teams: [SportsLiveTeam]) -> [SportsLiveEvent] {
        teams.map { team in
            SportsLiveEvent(id: "favorite-team-\(team.id)", title: team.name, subtitle: "Roster • schedule • players • scores • highlights", league: team.league, status: "My Team", artworkURL: team.badgeURL, accent: .yellow)
        }
    }

    func loadFavoriteTeams(_ raw: String) async -> [SportsLiveTeam] {
        let names = raw.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        var teams: [SportsLiveTeam] = []
        for name in names.prefix(8) {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            if let url = URL(string: "https://www.thesportsdb.com/api/v1/json/3/searchteams.php?t=\(encoded)"),
               let root = await fetchJSON(url),
               let arr = root["teams"] as? [[String: Any]],
               let team = arr.first {
                teams.append(SportsLiveTeam(id: team["idTeam"] as? String ?? name, name: team["strTeam"] as? String ?? name, league: team["strLeague"] as? String ?? "Favorite", badgeURL: team["strTeamBadge"] as? String ?? team["strTeamLogo"] as? String))
            } else {
                teams.append(SportsLiveTeam(id: name, name: name, league: "Favorite", badgeURL: nil))
            }
        }
        return teams
    }

    func makeTicker(events: [SportsLiveEvent], favorites: [SportsLiveTeam], channels: [SportsLiveEvent]) -> [String] {
        let orderedSports = ["NFL", "NBA", "MLB", "NHL", "WNBA", "NCAA", "Soccer", "UFC", "Boxing", "WWE", "AEW", "TNA", "NJPW", "F1", "NASCAR", "Tennis", "Golf", "PPV"]
        var picked: [SportsLiveEvent] = []
        for league in orderedSports {
            if let match = events.first(where: { $0.league.localizedCaseInsensitiveContains(league) || $0.title.localizedCaseInsensitiveContains(league) }) {
                picked.append(match)
            }
        }
        for event in events where picked.count < 18 && !picked.contains(where: { $0.id == event.id }) { picked.append(event) }
        var items = picked.prefix(18).map { "\($0.league) • \($0.title) • \($0.subtitle.isEmpty ? $0.status : $0.subtitle)" }
        items += favorites.prefix(6).map { "★ \($0.name) • team art ready" }
        if !channels.isEmpty { items.append("\(channels.count) manual sports source cards") }
        return items.isEmpty ? ["NFL • NBA • MLB • NHL • Soccer • NCAA • UFC • Boxing", "WWE • AEW • TNA • NJPW wrestling headlines ready", "F1 • NASCAR • Tennis • Golf", "Add favorite teams in Settings"] : items
    }

    func fallbackTodayEvents(favoriteTeams: String) -> [SportsLiveEvent] {
        let teams = favoriteTeams.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let names = teams.isEmpty ? ["NFL Live", "NBA Tonight", "MLB Live", "NHL Center Ice", "Soccer Today", "UFC Fight Night", "WWE Raw / SmackDown", "AEW Dynamite / Collision", "F1 Weekend", "Tennis Live", "Golf Central"] : teams
        return names.enumerated().map { idx, name in
            SportsLiveEvent(id: "fallback-today-\(idx)", title: name, subtitle: "Today", league: "Favorites", status: "Scheduled", artworkURL: nil, accent: .orange)
        }
    }

    private func fetchJSON(_ url: URL) async -> [String: Any]? {
        guard !Task.isCancelled, !VODExclusivePlaybackGate.isActive else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        req.setValue("DebridChannels-tvOS/560", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled, !VODExclusivePlaybackGate.isActive else { return nil }
            guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}
