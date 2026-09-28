import Foundation

// v779: Owns Movies/Shows release ticker item selection so the root overlay
// is a thin view wrapper.
final class MoviesShowsTickerManager {
    static let shared = MoviesShowsTickerManager()

    private init() {}

    func releaseItems(from rows: [MediaRow]) -> [MediaItem] {
        let flat = rows.flatMap { $0.items }
        let movies = flat.filter { item in
            item.type.lowercased().contains("movie")
        }
        let shows = flat.filter { item in
            let type = item.type.lowercased()
            return type.contains("series") || type.contains("show")
        }

        var mixed: [MediaItem] = []
        var movieIndex = 0
        var showIndex = 0
        while mixed.count < 24 && (movieIndex < movies.count || showIndex < shows.count) {
            if movieIndex < movies.count {
                mixed.append(movies[movieIndex])
                movieIndex += 1
            }
            if mixed.count >= 24 { break }
            if showIndex < shows.count {
                mixed.append(shows[showIndex])
                showIndex += 1
            }
        }

        return mixed
    }

    func badgeTitle(for item: MediaItem) -> String {
        item.type.lowercased().contains("movie") ? "NEW MOVIE WATCH" : "NEW SHOW WATCH"
    }

    func metadataLine(for item: MediaItem) -> String {
        [item.year, item.genres.prefix(2).joined(separator: " • ")]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
