import SwiftUI

// v776: Step 2 architecture migration.
// Sports Center MVVM adapter keeps existing Sports behavior intact while delegating
// sports channel taxonomy to SportsChannelClassifierManager.
@MainActor
final class SportsCenterViewModel: ObservableObject {
    @Published private(set) var sportsRows: [(String, [MediaItem])] = []
    @Published private(set) var sourceStatus: String = "Sports scores/schedules • sports-only M3U isolated"

    private let classifier = SportsChannelClassifierManager.shared

    // vBRDC091: Sports is not a persistent model surface. Release its mapped MediaItems
    // on exit so a briefly retained SwiftUI branch cannot keep an alternate channel-card
    // graph resident after Home/Movies/Shows retake the frame budget.
    func releaseForSurfaceExit() {
        sportsRows.removeAll(keepingCapacity: false)
        sourceStatus = "Sports scores/schedules • sports-only M3U isolated"
    }

    func refresh(
        channels: [LiveTVChannel],
        assignedGroupsRaw: String,
        manualChannelIdsRaw: String,
        excludedChannelIdsRaw: String = "",
        excludedChannelNamesRaw: String = "",
        currentProgram: (LiveTVChannel) -> LiveProgram?
    ) {
        let assignedGroups = Self.stringSet(fromPipeSeparated: assignedGroupsRaw)
        let manualIDs = Self.intSet(fromCommaSeparated: manualChannelIdsRaw)
        let excludedIDs = Self.intSet(fromCommaSeparated: excludedChannelIdsRaw)
        let excludedNames = Self.stringSet(fromPipeSeparated: excludedChannelNamesRaw)
        sportsRows = makeSportsRows(
            channels: channels,
            assignedGroups: assignedGroups,
            manualChannelIDs: manualIDs,
            excludedChannelIDs: excludedIDs,
            excludedChannelNames: excludedNames,
            currentProgram: currentProgram
        )
        sourceStatus = Self.makeSourceStatus(manualChannelIDs: manualIDs, assignedGroups: assignedGroups)
    }

    private func makeSportsRows(
        channels: [LiveTVChannel],
        assignedGroups: Set<String>,
        manualChannelIDs: Set<Int>,
        excludedChannelIDs: Set<Int>,
        excludedChannelNames: Set<String>,
        currentProgram: (LiveTVChannel) -> LiveProgram?
    ) -> [(String, [MediaItem])] {
        var grouped: [String: [MediaItem]] = [:]
        for channel in channels.prefix(600) {
            guard !excludedChannelIDs.contains(channel.id) else { continue }
            guard !excludedChannelNames.contains(Self.normalizedChannelName(channel.name)) else { continue }
            let manualOrAssigned = manualChannelIDs.contains(channel.id) || assignedGroups.contains(channel.category) || assignedGroups.contains(channel.source)
            let autoSection = classifier.sportsSection(for: channel)
            guard manualOrAssigned || autoSection != nil else { continue }
            let section = autoSection ?? "Sports / Other"
            let program = currentProgram(channel)
            let desc = program?.title ?? channel.description
            let subtitle = [channel.source, channel.category, program?.startText ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
            let item = MediaItem(
                id: "sports-live-\(channel.id)-\(channel.streamURL.hashValue)",
                title: channel.name,
                year: program?.isLive == true ? "LIVE" : "Live",
                type: "live",
                catalog: channel.source,
                description: desc.isEmpty ? channel.description : desc,
                genres: [section, subtitle].filter { !$0.isEmpty },
                rating: program?.isLive == true ? "LIVE" : "",
                posterURL: channel.bestArtworkURL,
                landscapeURL: channel.bestArtworkURL,
                logoURL: channel.bestArtworkURL,
                previewURL: channel.streamURL,
                addonName: section,
                addonIconURL: channel.bestArtworkURL
            )
            grouped[section, default: []].append(item)
        }
        return classifier.sectionOrder.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            return (section, Array(items.prefix(section == "Live Sports Channels" ? 48 : 36)))
        }
    }

    private static func makeSourceStatus(manualChannelIDs: Set<Int>, assignedGroups: Set<String>) -> String {
        if !manualChannelIDs.isEmpty || !assignedGroups.isEmpty {
            return "\(manualChannelIDs.count) channel(s) • \(assignedGroups.count) group(s) assigned"
        }
        return "Sports scores/schedules • sports-only M3U isolated"
    }

    private static func stringSet(fromPipeSeparated raw: String) -> Set<String> {
        Set(raw.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func intSet(fromCommaSeparated raw: String) -> Set<Int> {
        Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    private static func normalizedChannelName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "|", with: " ")
    }
}
