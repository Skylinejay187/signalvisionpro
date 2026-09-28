import SwiftUI
import Foundation

enum Phase15AudioAmplificationPreset: Double, CaseIterable, Hashable {
    case off = 0
    case db3 = 3
    case db6 = 6
    case db9 = 9
    case db12 = 12

    var displayName: String {
        self == .off ? "Off" : "+\(Int(rawValue)) dB"
    }

    var next: Phase15AudioAmplificationPreset {
        let values = Self.allCases
        guard let index = values.firstIndex(of: self) else { return .off }
        return values[(index + 1) % values.count]
    }

    static func normalized(_ raw: Double) -> Phase15AudioAmplificationPreset {
        guard raw.isFinite,
              let exact = Self.allCases.first(where: { abs($0.rawValue - raw) < 0.01 }) else { return .off }
        return exact
    }
}

struct Phase15VODEpisodeBrowserOverlay: View {
    let seriesTitle: String
    let currentItemID: String
    let episodes: [MediaItem]
    let isLoading: Bool
    let errorMessage: String?
    let onEpisodeSelected: (MediaItem) -> Void
    let onClose: () -> Void

    @State private var selectedSeason: Int? = nil
    @State private var preparedRows: [Phase15EpisodeBrowserRow] = []
    @State private var preparedSeasons: [Int] = []

    private let gridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(minimum: 260), spacing: 16, alignment: .top),
        count: 4
    )

    private var episodeIndexSignature: String {
        let first = episodes.first?.id ?? ""
        let last = episodes.last?.id ?? ""
        return "\(seriesTitle)|\(episodes.count)|\(first)|\(last)"
    }

    private var filteredRows: [Phase15EpisodeBrowserRow] {
        guard let selectedSeason else { return preparedRows }
        return preparedRows.filter { $0.season == selectedSeason }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            LinearGradient(
                colors: [Color.black, Color.orange.opacity(0.045), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                seasonStrip
                episodeContent
            }
            .padding(.horizontal, 68)
            .padding(.top, 46)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        .onAppear {
            rebuildEpisodeIndex()
        }
        .onChange(of: episodeIndexSignature) { _, _ in
            rebuildEpisodeIndex()
        }
        .signalPlatformExitCommand(onClose)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Phase15VODEpisodeBrowserOverlay")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("FULL EPISODE BROWSER")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(Color.orange.opacity(0.94))
            Text(seriesTitle)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("Choose a season, select the episode you want, and press Back to return to playback.")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var seasonStrip: some View {
        if !preparedSeasons.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Phase15SeasonFilterChip(title: "All Seasons", selected: selectedSeason == nil) {
                        selectedSeason = nil
                    }
                    ForEach(preparedSeasons, id: \.self) { season in
                        Phase15SeasonFilterChip(title: "Season \(season)", selected: selectedSeason == season) {
                            selectedSeason = season
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled(true)
            .signalPlatformFocusSection()
        }
    }

    @ViewBuilder
    private var episodeContent: some View {
        if isLoading {
            Spacer()
            HStack(spacing: 14) {
                ProgressView()
                Text("Loading the complete episode list…")
                    .font(.system(size: 22, weight: .black, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if let errorMessage, episodes.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.90))
                Text("Episode list unavailable")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                Text(errorMessage)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if filteredRows.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No episodes are available for this season.")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(filteredRows) { row in
                        Phase15EpisodeCard(
                            row: row,
                            isCurrent: row.episode.id == currentItemID,
                            onSelect: { onEpisodeSelected(row.episode) }
                        )
                    }
                }
                .padding(.vertical, 10)
                .padding(.bottom, 44)
            }
            .signalPlatformFocusSection()
            .transaction { transaction in
                // Grid movement should never animate a complete relayout. Each focused card
                // owns its tiny focus-scale animation independently.
                transaction.disablesAnimations = true
            }
        }
    }

    private func rebuildEpisodeIndex() {
        let rows = Phase15EpisodeBrowserRow.prepare(episodes)
        preparedRows = rows
        preparedSeasons = Array(Set(rows.map(\.season).filter { $0 > 0 })).sorted()
        if let selectedSeason, !preparedSeasons.contains(selectedSeason) {
            self.selectedSeason = nil
        }
    }
}

private struct Phase15EpisodeBrowserRow: Identifiable {
    let episode: MediaItem
    let code: String
    let displayTitle: String
    let airDateLine: String
    let season: Int
    let episodeNumber: Int
    let artworkURL: String?

    var id: String { episode.id }

    static func prepare(_ episodes: [MediaItem]) -> [Phase15EpisodeBrowserRow] {
        episodes.map { episode in
            let season = episode.seasonNumber ?? 1
            let number = episode.episodeNumber ?? 1
            let code = "S\(season)E\(number)"
            let title = cleanTitle(episode.title, fallback: code)
            let airDateLine = Phase15EpisodeAirDateLabel.line(for: episode)
            let artworkURL = [episode.landscapeURL, episode.previewURL, episode.posterURL]
                .compactMap { value -> String? in
                    let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return clean.isEmpty ? nil : clean
                }
                .first
            return Phase15EpisodeBrowserRow(
                episode: episode,
                code: code,
                displayTitle: title,
                airDateLine: airDateLine,
                season: season,
                episodeNumber: number,
                artworkURL: artworkURL
            )
        }
        .sorted { lhs, rhs in
            if lhs.season != rhs.season { return lhs.season < rhs.season }
            return lhs.episodeNumber < rhs.episodeNumber
        }
    }

    private static func cleanTitle(_ raw: String, fallback: String) -> String {
        var value = raw
        if let range = value.range(of: #"S\d{1,2}E\d{1,3}"#, options: .regularExpression) {
            value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? fallback : value
    }
}

private struct Phase15SeasonFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    private var fill: Color {
        if focused { return Color.orange.opacity(0.78) }
        if selected { return Color.orange.opacity(0.48) }
        return Color.white.opacity(0.085)
    }

    private var stroke: Color {
        if focused { return Color.orange.opacity(0.98) }
        if selected { return Color.orange.opacity(0.72) }
        return Color.white.opacity(0.12)
    }

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: focused ? 2 : 1))
            .contentShape(Capsule())
            .focusable(true)
            .focused($focused)
            .onTapGesture(perform: action)
            .scaleEffect(focused ? 1.035 : 1)
            .animation(.easeOut(duration: 0.10), value: focused)
            .accessibilityAddTraits(.isButton)
    }
}

private struct Phase15EpisodeCard: View {
    let row: Phase15EpisodeBrowserRow
    let isCurrent: Bool
    let onSelect: () -> Void
    @FocusState private var focused: Bool

    private var resumeEntry: PlaybackResumeEntry? {
        PlaybackResumeCacheManager.shared.resumeEntry(for: row.episode)
    }

    var body: some View {
        accessibleCard
    }

    private var accessibleCard: some View {
        animatedCard
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(row.code), \(row.displayTitle)")
            .accessibilityHint(isCurrent ? "Currently playing" : "Select to confirm switching playback to this episode")
    }

    private var animatedCard: some View {
        interactiveCard
            .scaleEffect(focused ? 1.018 : 1)
            .animation(.easeOut(duration: 0.10), value: focused)
    }

    private var interactiveCard: some View {
        cardSurface
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .focusable(true)
            .focused($focused)
            .onTapGesture(perform: onSelect)
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkSurface
            Text(row.airDateLine)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.orange.opacity(0.88))
                .lineLimit(1)
            Text(row.displayTitle)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(2)
            Text(row.episode.description)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var artworkSurface: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.055))
            if let artwork = row.artworkURL, !artwork.isEmpty {
                // vBRDC123: this grid is a foreground VOD surface. Episode stills must
                // paint while the playback session remains mounted/paused; otherwise the
                // durable frame gate can leave decoded cards blank until a season remount.
                RemoteImageFit(
                    url: artwork,
                    mode: .fill,
                    showPlaceholder: false,
                    maxPixelSize: 768,
                    publishDuringPlayback: true,
                    forceVisiblePlaybackPublication: true
                )
            } else {
                Image(systemName: "tv.inset.filled")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.24))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let resume = resumeEntry, resume.duration > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .black))
                    Text("\(resume.dcRemainingText.uppercased()) LEFT")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .tracking(0.45)
                }
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.cyan.opacity(0.84)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(9)
            }
            if isCurrent {
                Text("NOW PLAYING")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .tracking(0.8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.90)))
                    .padding(9)
            }
        }
        .frame(height: 142)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(focused ? Color.orange.opacity(0.075) : Color.black.opacity(0.30))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(
                focused ? Color.orange.opacity(0.96) : Color.white.opacity(0.11),
                lineWidth: focused ? 2 : 1
            )
    }
}

private enum Phase15EpisodeAirDateLabel {
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoFormatter = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
    private static let fallbackFormatters: [DateFormatter] = ["yyyy-MM-dd", "yyyy/MM/dd", "MMM d, yyyy"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    static func line(for episode: MediaItem) -> String {
        let code = "S\(episode.seasonNumber ?? 1)E\(episode.episodeNumber ?? 1)"
        guard let raw = episode.airDateString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return code }
        guard let date = parse(raw) else { return "\(code) • \(raw)" }
        let calendar = Calendar.current
        let status: String
        if calendar.isDateInToday(date) {
            status = "TODAY"
        } else if date > Date() {
            status = "UPCOMING"
        } else {
            status = "AIRED"
        }
        return "\(code) • \(status) \(displayFormatter.string(from: date))"
    }

    private static func parse(_ value: String) -> Date? {
        if let date = isoFractionalFormatter.date(from: value) { return date }
        if let date = isoFormatter.date(from: value) { return date }
        for formatter in fallbackFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}


struct Phase15VODSourcePickerOverlay: View {
    let target: MediaItem
    let sources: [StreamLink]
    let isWorking: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSelect: (StreamLink) -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.90).ignoresSafeArea()
            LinearGradient(
                colors: [Color.black, Color.orange.opacity(0.045), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SOURCE INTELLIGENCE")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(Color.orange.opacity(0.96))
                        Text(target.title)
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Choose the exact ranked link to play. Your current video stays paused and unchanged until the selected source passes preflight and the new playback presentation opens.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(2)
                    }
                    Spacer()
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(closeFocused ? .black : .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(closeFocused ? Color.white : Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                        .focusable(!isWorking)
                        .focused($closeFocused)
                        .onTapGesture { if !isWorking { onCancel() } }
                        .opacity(isWorking ? 0.55 : 1)
                        .accessibilityAddTraits(.isButton)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange.opacity(0.94))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.08)))
                }

                if isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Opening selected source…")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .padding(.vertical, 8)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 11) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            Phase15VODSourcePickerRow(
                                rank: index + 1,
                                source: source,
                                disabled: isWorking,
                                onSelect: { onSelect(source) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.bottom, 34)
                }
                .signalPlatformFocusSection()
            }
            .padding(.horizontal, 72)
            .padding(.top, 50)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
        .onAppear { closeFocused = false }
        .signalPlatformExitCommand { if !isWorking { onCancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Phase15VODSourcePickerOverlay")
    }
}

private struct Phase15VODSourcePickerRow: View {
    let rank: Int
    let source: StreamLink
    let disabled: Bool
    let onSelect: () -> Void
    @FocusState private var focused: Bool

    private var fileLabel: String {
        let value = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Direct stream" : value
    }

    var body: some View {
        accessibleRow
    }

    private var accessibleRow: some View {
        animatedRow
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(sourceAccessibilityLabel)
            .accessibilityHint("Play this source")
    }

    private var animatedRow: some View {
        interactiveRow
            .opacity(disabled ? 0.55 : 1)
            .scaleEffect(focused ? 1.018 : 1)
            .animation(.easeOut(duration: 0.13), value: focused)
    }

    private var interactiveRow: some View {
        rowSurface
            .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .focusable(!disabled)
            .focused($focused)
            .onTapGesture(perform: activateIfEnabled)
    }

    private var rowSurface: some View {
        HStack(spacing: 16) {
            Text("#\(rank)")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(rankColor)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 6) {
                sourceBadges
                Text(fileLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(fileLabelColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .black))
        }
        .foregroundStyle(focused ? Color.black : Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(rowBorder)
    }

    private var sourceBadges: some View {
        HStack(spacing: 9) {
            Text(source.providerDisplay)
                .font(.system(size: 17, weight: .black, design: .rounded))
            Phase15SourceBadge(text: source.sourceIntelligenceCacheLabel, highlighted: source.sourceIntelligenceIsCached)
            Phase15SourceBadge(text: source.sourceIntelligenceLanguageLabel, highlighted: source.sourceIntelligenceIsEnglish)
            Phase15SourceBadge(text: source.quality, highlighted: false)
            Phase15SourceBadge(text: source.size, highlighted: false)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
            .fill(focused ? Color.white.opacity(0.94) : Color.white.opacity(0.065))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
            .stroke(
                focused ? Color.orange.opacity(0.94) : Color.white.opacity(0.10),
                lineWidth: focused ? 2 : 1
            )
    }

    private var rankColor: Color {
        focused ? Color.black.opacity(0.78) : Color.orange.opacity(0.92)
    }

    private var fileLabelColor: Color {
        focused ? Color.black.opacity(0.62) : Color.white.opacity(0.48)
    }

    private var sourceAccessibilityLabel: String {
        "Rank \(rank), \(source.providerDisplay), \(source.quality), \(source.size), \(source.sourceIntelligenceCacheLabel)"
    }

    private func activateIfEnabled() {
        guard !disabled else { return }
        onSelect()
    }
}

private struct Phase15SourceBadge: View {
    let text: String
    let highlighted: Bool

    private var displayText: String {
        text.isEmpty ? "Unknown" : text
    }

    private var labelColor: Color {
        highlighted ? Color.orange.opacity(0.96) : Color.white.opacity(0.62)
    }

    private var borderColor: Color {
        highlighted ? Color.orange.opacity(0.45) : Color.white.opacity(0.10)
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundColor(labelColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.28))
            )
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

struct Phase15VODSwitchConfirmationOverlay: View {
    let currentTitle: String
    let target: MediaItem
    let contextLabel: String
    let isWorking: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case cancel, confirm }

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("SWITCH PLAYBACK?")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.orange.opacity(0.94))
                Text("Watch \(target.title)?")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("You’re currently watching \(currentTitle). Debrid Channels will keep the current playback paused while it loads ranked Source Intelligence links. You choose the exact link before anything switches.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(4)
                Text(contextLabel)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                if isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Finding the best available source…")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.74))
                }
                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange.opacity(0.92))
                        .lineLimit(3)
                }
                HStack(spacing: 14) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(focusedAction == .cancel ? .black : .white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(focusedAction == .cancel ? Color.white : Color.white.opacity(0.11)))
                        .contentShape(Capsule())
                        .focusable(!isWorking)
                        .focused($focusedAction, equals: .cancel)
                        .onTapGesture { if !isWorking { onCancel() } }
                        .opacity(isWorking ? 0.55 : 1)
                        .accessibilityAddTraits(.isButton)

                    Text(isWorking ? "Loading Sources…" : "Continue to Sources")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(focusedAction == .confirm ? .black : .white)
                        .lineLimit(1)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(focusedAction == .confirm ? Color.white : Color.orange.opacity(0.82)))
                        .contentShape(Capsule())
                        .focusable(!isWorking)
                        .focused($focusedAction, equals: .confirm)
                        .onTapGesture { if !isWorking { onConfirm() } }
                        .opacity(isWorking ? 0.55 : 1)
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(30)
            .frame(width: 660, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 34, y: 14)
        }
        .onAppear { focusedAction = .cancel }
        .signalPlatformExitCommand { if !isWorking { onCancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Phase15VODSwitchConfirmationOverlay")
    }
}

// Build 15: preserve tvOS directional-focus/remote behavior, while allowing the
// same full overlays to compile on visionOS, where these APIs are unavailable.
// Each overlay retains its visible Close / Cancel control for spatial input.
private extension View {
    @ViewBuilder
    func signalPlatformFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func signalPlatformExitCommand(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
