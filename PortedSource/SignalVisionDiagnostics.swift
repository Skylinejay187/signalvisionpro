import Foundation
import SwiftUI
import UIKit

/// Local, explicitly scoped diagnostics: no URLs, credentials, channel titles or media data.
/// This file is saved in Application Support so reports survive relaunch and require no Mac.
@MainActor
final class SignalVisionDiagnostics: ObservableObject {
    static let shared = SignalVisionDiagnostics()
    @Published private(set) var recent: String = ""
    let fileURL: URL
    private let formatter = ISO8601DateFormatter()
    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SignalVisionDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("Signal-Cinema-Diagnostics.txt")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        record("diagnostics", "session-start build=29 visionOS=\(UIDevice.current.systemVersion)")
    }

    func record(_ category: String, _ event: String) {
        // Call sites only supply controlled enum-like lifecycle/status strings.
        let line = "\(formatter.string(from: Date())) [\(category)] \(event)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { /* fail closed */ }
        }
        recent = String((recent + line).suffix(18000))
        print("[SignalVisionDiagnostics] \(category) \(event)")
    }

    func sceneSnapshot(_ context: String) {
        let scenes = UIApplication.shared.connectedScenes.map {
            "\(String(describing: type(of: $0))):\(String(describing: $0.activationState))"
        }.sorted().joined(separator: ",")
        let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        // Read the installed bundle, NOT project.yml or the uncompiled source plist.
        // Distinguish absent/mistyped manifest values from an actual false value.
        let raw = manifest?["UIApplicationSupportsMultipleScenes"]
        let multiple = raw as? Bool
        let multipleStatus = multiple.map(String.init(describing:)) ?? "MISSING_OR_INVALID"
        let configurationPresent = manifest?["UISceneConfigurations"] is [String: Any]
        let role = Bundle.main.object(forInfoDictionaryKey: "UIApplicationPreferredDefaultSceneSessionRole") as? String ?? "not-set"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "not-set"
        record("scenes", "\(context) multiple=\(multipleStatus) manifestPresent=\(manifest != nil) sceneConfigurationsPresent=\(configurationPresent) defaultRole=\(role) bundleVersion=\(version) connected=[\(scenes)]")
    }

    func exportFile() -> URL {
        record("export", "user-requested diagnostics export")
        return fileURL
    }
}

struct SignalVisionDiagnosticsPanel: View {
    @ObservedObject private var diagnostics = SignalVisionDiagnostics.shared
    @State private var exportURL: URL?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cinema diagnostics").font(.title2.bold())
                Text("Only Signal scene/entry events are collected. No account tokens, streaming links or personal media information are intentionally recorded.")
                    .font(.subheadline)
                Button("Capture scene status") { diagnostics.sceneSnapshot("user-capture") }
                    .buttonStyle(.bordered)
                Button("Prepare diagnostics for sharing") { exportURL = diagnostics.exportFile() }
                    .buttonStyle(.borderedProminent)
                if let exportURL {
                    ShareLink(item: exportURL, preview: SharePreview("Signal Cinema Diagnostics")) {
                        Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Save the text file to Files or share it to your phone, then upload it in this chat.")
                        .font(.caption)
                }
                Text(diagnostics.recent.isEmpty ? "No captured events yet." : diagnostics.recent)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }.padding(24)
        }
        .frame(width: 620, height: 600)
        .onAppear { diagnostics.sceneSnapshot("diagnostics-opened") }
    }
}
