import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded on-disk cache for focused-card preview media. Progressive MP4/MOV/M4V
/// responses are retained in the system Caches directory so revisiting a row does not
/// download the same preview again. Adaptive manifests continue to use the backend's
/// reuseCache/singleFlight lane because an HLS package cannot safely be copied as one file.
actor FocusedCardPreviewDiskCache {
    static let shared = FocusedCardPreviewDiskCache()

    private let fileManager = FileManager.default
    private let directory: URL
    private let maximumFileCount = 18
    private let maximumTotalBytes: Int64 = 768 * 1024 * 1024
    private let maximumSingleFileBytes: Int64 = 96 * 1024 * 1024
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    private init() {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = root.appendingPathComponent("FocusedCardPreviews-v1015", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedFileURL(forKey key: String) -> URL? {
        let stem = stableStem(for: key)
        for ext in ["mp4", "mov", "m4v"] {
            let candidate = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            if fileManager.fileExists(atPath: candidate.path) {
                if isExpired(candidate) {
                    try? fileManager.removeItem(at: candidate)
                    continue
                }
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
                return candidate
            }
        }
        return nil
    }

    func stageProgressivePreview(from remoteURL: URL, forKey key: String) async -> URL? {
        if let cached = cachedFileURL(forKey: key) { return cached }
        pruneIfNeeded(aggressive: false)
        guard hasSufficientFreeSpace(requiredBytes: 16 * 1024 * 1024) else {
            print("[FocusedCardPreviewCache][Phase7] skipped staging because free storage is low")
            return nil
        }
        guard let scheme = remoteURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }

        let remoteExtension = remoteURL.pathExtension.lowercased()
        if ["m3u8", "mpd", "ts"].contains(remoteExtension) { return nil }

        var expectedLength: Int64 = 0
        var headMIME = ""
        var headRequest = URLRequest(url: remoteURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        headRequest.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: headRequest),
           let http = response as? HTTPURLResponse {
            expectedLength = max(0, http.expectedContentLength)
            headMIME = (http.mimeType ?? "").lowercased()
        }
        if expectedLength > maximumSingleFileBytes || isAdaptiveMIME(headMIME) { return nil }
        if expectedLength > 0, !hasSufficientFreeSpace(requiredBytes: expectedLength) {
            print("[FocusedCardPreviewCache][Phase7] skipped \(expectedLength)-byte preview because free storage is low")
            return nil
        }

        do {
            var request = URLRequest(url: remoteURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 45)
            request.setValue("video/mp4,video/quicktime,video/x-m4v,*/*", forHTTPHeaderField: "Accept")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard !Task.isCancelled else { try? fileManager.removeItem(at: temporaryURL); return nil }

            let mime = ((response as? HTTPURLResponse)?.mimeType ?? headMIME).lowercased()
            guard !isAdaptiveMIME(mime) else { try? fileManager.removeItem(at: temporaryURL); return nil }

            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize > 0, fileSize <= maximumSingleFileBytes else {
                try? fileManager.removeItem(at: temporaryURL)
                return nil
            }

            let ext = preferredExtension(remoteExtension: remoteExtension, mime: mime)
            let destination = directory.appendingPathComponent(stableStem(for: key)).appendingPathExtension(ext)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            pruneIfNeeded(aggressive: false)
            print("[FocusedCardPreviewCache] stored \(destination.lastPathComponent) bytes=\(fileSize)")
            return destination
        } catch {
            return nil
        }
    }

    private func preferredExtension(remoteExtension: String, mime: String) -> String {
        if ["mp4", "mov", "m4v"].contains(remoteExtension) { return remoteExtension }
        if mime.contains("quicktime") { return "mov" }
        if mime.contains("x-m4v") { return "m4v" }
        return "mp4"
    }

    private func isAdaptiveMIME(_ mime: String) -> Bool {
        mime.contains("mpegurl") || mime.contains("dash") || mime.contains("mp2t")
    }

    private func stableStem(for key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    func performMaintenance(aggressive: Bool) {
        pruneIfNeeded(aggressive: aggressive)
    }

    private func isExpired(_ url: URL, now: Date = Date()) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return false }
        return now.timeIntervalSince(date) > maximumAge
    }

    private func hasSufficientFreeSpace(requiredBytes: Int64) -> Bool {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: directory.path),
              let number = attributes[.systemFreeSize] as? NSNumber else { return true }
        return number.int64Value > minimumFreeBytes + max(0, requiredBytes)
    }

    private func pruneIfNeeded(aggressive: Bool) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var entries: [(url: URL, size: Int64, date: Date)] = []
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maximumAge {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append((url, Int64(values.fileSize ?? 0), date))
        }
        entries.sort { $0.date > $1.date }

        let fileLimit = aggressive ? 6 : maximumFileCount
        let byteLimit = aggressive ? min(maximumTotalBytes, 256 * 1024 * 1024) : maximumTotalBytes
        var retainedBytes: Int64 = 0
        for (index, entry) in entries.enumerated() {
            retainedBytes += entry.size
            if index >= fileLimit || retainedBytes > byteLimit {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }
}
