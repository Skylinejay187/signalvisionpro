import Foundation

// v776: Step 2 architecture migration.
// Centralizes sports channel classification rules so Sports Center UI/ViewModel
// no longer owns keyword taxonomy. Behavior intentionally matches v775.
struct SportsChannelClassifierManager {
    static let shared = SportsChannelClassifierManager()

    let sectionOrder: [String] = [
        "Live Sports Channels", "NFL", "NBA", "MLB", "NHL", "Soccer", "Wrestling",
        "UFC / MMA", "Boxing", "Motorsports", "College Sports", "Regional Sports",
        "Sports News", "Sports / Other"
    ]

    private let noiseTokens = [
        " fhd", " uhd", " 4k", " hd", " 1080p", " 720p", " usa", " us", " ca", " uk", " vip", " backup", " stream", " channel"
    ]

    func sportsSection(for channel: LiveTVChannel) -> String? {
        let raw = [channel.name, channel.category, channel.source, channel.tvgID, channel.now, channel.next, channel.description]
            .joined(separator: " ")
            .lowercased()
        return sportsSection(forRawText: raw)
    }

    func sportsSection(forRawText raw: String) -> String? {
        var cleaned = raw.lowercased()
        for token in noiseTokens { cleaned = cleaned.replacingOccurrences(of: token, with: " ") }
        func has(_ words: [String]) -> Bool { words.contains { cleaned.contains($0) } }

        if has(["nfl", "redzone", "nfl network", "super bowl", "monday night football", "sunday ticket", "college football", "football night", "gridiron", "sec football", "big ten football"]) { return "NFL" }
        if has(["nba", "nba tv", "basketball", "lakers", "celtics", "warriors", "knicks", "cavaliers", "bulls", "heat", "suns", "mavericks", "bucks", "76ers", "nuggets", "wnba"]) { return "NBA" }
        if has(["mlb", "baseball", "mlb network", "yankees", "dodgers", "red sox", "mets", "guardians", "cubs", "braves", "phillies", "astros", "cardinals", "orioles"]) { return "MLB" }
        if has(["nhl", "hockey", "nhl network", "penguins", "rangers", "bruins", "leafs", "maple leafs", "canadiens", "oilers", "blackhawks", "kings", "flyers", "devils"]) { return "NHL" }
        if has(["soccer", "futbol", "football club", "fc ", "premier league", "epl", "mls", "la liga", "serie a", "bundesliga", "champions league", "europa", "bein", "inter miami", "sky sports premier", "tudn", "gol tv", "fox deportes"]) { return "Soccer" }
        if has(["wwe", "aew", "tna", "impact wrestling", "nxt", "raw", "smackdown", "wrestling", "njpw", "roh", "ring of honor"]) { return "Wrestling" }
        if has(["ufc", "mma", "bellator", "pfl", "one championship", "fight night", "cage", "mixed martial"]) { return "UFC / MMA" }
        if has(["boxing", "boxeo", "top rank", "pbc", "golden boy", "fight sports", "triller fight"]) { return "Boxing" }
        if has(["f1", "formula", "nascar", "racing", "motorsport", "indycar", "motogp", "supercross", "imsa", "le mans"]) { return "Motorsports" }
        if has(["college", "ncaa", "sec network", "acc network", "big ten", "btn", "pac-12", "march madness", "college sports", "espnu"]) { return "College Sports" }
        if has(["rsn", "regional sports", "bally", "fan duel sports", "masn", "yes network", "nesn", "msg", "sportsnet", "nbc sports", "root sports", "marquee", "altitude", "sny", "monumental"]) { return "Regional Sports" }
        if has(["sportscenter", "sports centre", "espnews", "nfl live", "nba today", "mlb tonight", "nhl tonight", "fox sports live", "cbs sports hq", "sports news"]) { return "Sports News" }
        if has(["espn", "espn2", "fs1", "fs2", "fox sports", "cbs sports", "tnt sports", "dazn", "sport", "sports", "ppv", "event", "events", "match", "game day"]) { return "Live Sports Channels" }
        return nil
    }
}
