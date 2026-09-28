import Foundation
import SwiftUI

// v777: Step 3 architecture migration.
// Owns public sports score/schedule fetching so SportsLiveZoneModel keeps app state only.
// Output mapping intentionally matches v776 to preserve Sports Center and ticker behavior.
// vBRDC091: network/JSON work is intentionally non-MainActor; only the Sports view model publishes on MainActor.
struct SportsScoresScheduleProvider {
    static let shared = SportsScoresScheduleProvider()

    func loadSportsDBToday() async -> [SportsLiveEvent] {
        let today = Self.dayString(Date())
        let sports = ["Soccer", "American Football", "Basketball", "Baseball", "Ice Hockey", "Motorsport", "Fighting", "Tennis", "Golf"]
        var output: [SportsLiveEvent] = []
        for sport in sports {
            let encoded = sport.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sport
            guard let url = URL(string: "https://www.thesportsdb.com/api/v1/json/3/eventsday.php?d=\(today)&s=\(encoded)"),
                  let root = await fetchJSON(url),
                  let events = root["events"] as? [[String: Any]] else { continue }
            output += events.prefix(10).compactMap { item in
                let home = item["strHomeTeam"] as? String ?? "Home"
                let away = item["strAwayTeam"] as? String ?? "Away"
                let league = item["strLeague"] as? String ?? sport
                let time = item["strTime"] as? String ?? item["dateEvent"] as? String ?? "Today"
                let status = item["strStatus"] as? String ?? "Scheduled"
                let art = item["strThumb"] as? String ?? item["strPoster"] as? String ?? item["strFanart"] as? String
                let id = item["idEvent"] as? String ?? "sportsdb-\(sport)-\(home)-\(away)-\(time)"
                return SportsLiveEvent(id: "sportsdb-\(id)", title: "\(away) at \(home)", subtitle: time, league: league, status: status, artworkURL: art, accent: .orange)
            }
            if output.count >= 36 { break }
        }
        return Array(output.prefix(36))
    }

    func loadESPNScores() async -> [SportsLiveEvent] {
        let endpoints = [
            ("NFL", "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"),
            ("NCAAF", "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard"),
            ("NBA", "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard"),
            ("WNBA", "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/scoreboard"),
            ("NCAAM", "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard"),
            ("MLB", "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard"),
            ("NHL", "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard"),
            ("Soccer", "https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard"),
            ("UFC", "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"),
            ("F1", "https://site.api.espn.com/apis/site/v2/sports/racing/f1/scoreboard")
        ]
        var output: [SportsLiveEvent] = []
        for (league, raw) in endpoints {
            guard let url = URL(string: raw), let root = await fetchJSON(url), let events = root["events"] as? [[String: Any]] else { continue }
            for event in events.prefix(10) {
                let name = event["shortName"] as? String ?? event["name"] as? String ?? league
                let statusDict = event["status"] as? [String: Any]
                let statusType = statusDict?["type"] as? [String: Any]
                let status = statusType?["shortDetail"] as? String ?? statusType?["description"] as? String ?? "Scheduled"
                let competitions = event["competitions"] as? [[String: Any]]
                let competitors = competitions?.first?["competitors"] as? [[String: Any]] ?? []
                let art = competitors.compactMap { comp -> String? in
                    let team = comp["team"] as? [String: Any]
                    if let logo = team?["logo"] as? String { return logo }
                    if let logos = team?["logos"] as? [[String: Any]] { return logos.first?["href"] as? String }
                    return nil
                }.first
                let scoreLine = competitors.compactMap { comp -> String? in
                    let team = comp["team"] as? [String: Any]
                    let abbr = team?["abbreviation"] as? String ?? team?["shortDisplayName"] as? String
                    let score = comp["score"] as? String
                    guard let abbr else { return nil }
                    return score == nil ? abbr : "\(abbr) \(score!)"
                }.joined(separator: "  ")
                let id = event["id"] as? String ?? "espn-\(league)-\(name)"
                let subtitle = scoreLine.isEmpty ? status : scoreLine
                output.append(SportsLiveEvent(id: "espn-\(league)-\(id)", title: name, subtitle: subtitle, league: league, status: status, artworkURL: art, accent: .green))
            }
        }
        return output
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

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
