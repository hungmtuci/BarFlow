import Foundation
import AppKit

/// Checks `hungmtuci/BarFlow` GitHub Releases and performs 1-click download, atomic installation,
/// Gatekeeper quarantine removal (`xattr -cr`), and seamless app relaunch.
@MainActor
final class UpdateCheckerService: ObservableObject {
    static let shared = UpdateCheckerService()

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, zipURL: URL?, releasePageURL: URL)
        case downloading(version: String)
        case installing(version: String)
        case failed(message: String)
    }

    private struct GitHubReleaseResponse: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable, Sendable {
        let name: String
        let browser_download_url: String
    }

    @Published private(set) var state: UpdateState = .idle

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.8.1"
    }

    private var lastAutoCheckTimestamp: CFAbsoluteTime = 0
    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/hungmtuci/BarFlow/releases/latest")!
    private let releasesPageFallback = URL(string: "https://github.com/hungmtuci/BarFlow/releases/latest")!

    private init() {}

    /// Performs a quiet background check at most once every 6 hours without disturbing the user on network errors.
    func checkSilentlyOnLaunchIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard (now - lastAutoCheckTimestamp) >= 21_600 else { return }
        lastAutoCheckTimestamp = now
        Task { @MainActor in
            await performCheck(manual: false)
        }
    }

    /// Triggered explicitly by the user from the UI or the Menu Bar context menu.
    func checkForUpdatesManually() {
        Task { @MainActor in
            await performCheck(manual: true)
        }
    }

    private func performCheck(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }

        if manual {
            state = .checking
            MenuBarController.shared.statusMessage = "Đang kiểm tra phiên bản mới trên GitHub Releases..."
        }

        var req = URLRequest(url: latestReleaseAPI)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BarFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if manual {
                    let msg = "Không kết nối được GitHub Releases. Hãy thử lại sau."
                    state = .failed(message: msg)
                    MenuBarController.shared.statusMessage = msg
                }
                return
            }

            let decoded = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            let remoteVersion = Self.cleanVersionString(decoded.tag_name)
            let pageURL = URL(string: decoded.html_url) ?? releasesPageFallback

            let zipAssetURL: URL? = decoded.assets
                .first(where: { $0.name.lowercased().hasSuffix(".zip") })
                .flatMap { URL(string: $0.browser_download_url) }

            let localVer = currentVersion
            if Self.isVersion(remoteVersion, newerThan: localVer) {
                state = .available(version: remoteVersion, zipURL: zipAssetURL, releasePageURL: pageURL)
                if manual {
                    MenuBarController.shared.statusMessage = "Đã có bản mới BarFlow v\(remoteVersion)! Bấm 'Cập nhật v\(remoteVersion)' để tự động cài đặt."
                }
            } else {
                state = .upToDate(version: localVer)
                if manual {
                    MenuBarController.shared.statusMessage = "Bạn đang sử dụng phiên bản BarFlow mới nhất (v\(localVer))."
                }
            }
        } catch {
            if manual {
                let msg = "Không thể kiểm tra cập nhật (\(error.localizedDescription))."
                state = .failed(message: msg)
                MenuBarController.shared.statusMessage = msg
            }
        }
    }

    /// Downloads the release `.zip` archive, extracts `BarFlow.app`, replaces `/Applications/BarFlow.app`,
    /// strips Gatekeeper quarantine flags, and relaunches automatically.
    func installAvailableUpdate() {
        guard case let .available(version, zipURL, releasePageURL) = state else { return }

        guard let downloadURL = zipURL else {
            NSWorkspace.shared.open(releasePageURL)
            return
        }

        state = .downloading(version: version)
        MenuBarController.shared.statusMessage = "Đang tải BarFlow v\(version) từ GitHub..."

        Task { @MainActor in
            let stageDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("BarFlowAutoUpdate-\(UUID().uuidString)", isDirectory: true)
            let zipDest = stageDir.appendingPathComponent("BarFlow-update.zip")
            let extractDir = stageDir.appendingPathComponent("extracted", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                var req = URLRequest(url: downloadURL)
                req.timeoutInterval = 60
                req.setValue("BarFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (tempDownloadedURL, response) = try await URLSession.shared.download(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "BarFlowUpdate", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Mã phản hồi HTTP \(http.statusCode)"
                    ])
                }

                if FileManager.default.fileExists(atPath: zipDest.path) {
                    try? FileManager.default.removeItem(at: zipDest)
                }
                try FileManager.default.moveItem(at: tempDownloadedURL, to: zipDest)

                state = .installing(version: version)
                MenuBarController.shared.statusMessage = "Đang giải nén và cài đặt BarFlow v\(version)..."

                let extractedAppURL = try await Self.extractAndValidateZipOffMain(
                    zipPath: zipDest.path,
                    extractDirPath: extractDir.path
                )

                let targetAppPath: String = {
                    let appsDir = "/Applications"
                    if Bundle.main.bundlePath.hasPrefix("/Applications/") || FileManager.default.isWritableFile(atPath: appsDir) {
                        return "/Applications/BarFlow.app"
                    }
                    return Bundle.main.bundlePath
                }()

                let currentPID = ProcessInfo.processInfo.processIdentifier
                try Self.spawnDetachedSwapAndRelaunch(
                    oldPID: currentPID,
                    extractedAppPath: extractedAppURL.path,
                    targetAppPath: targetAppPath,
                    stageDirPath: stageDir.path
                )

                MenuBarController.shared.prepareForTermination()
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: stageDir)
                let msg = "Cập nhật tự động thất bại: \(error.localizedDescription) — đang mở trang tải thủ công..."
                state = .failed(message: msg)
                MenuBarController.shared.statusMessage = msg
                NSWorkspace.shared.open(releasePageURL)
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func extractAndValidateZipOffMain(
        zipPath: String,
        extractDirPath: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", zipPath, extractDirPath]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        throw NSError(domain: "BarFlowUpdate", code: Int(proc.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: "Giải nén gói cập nhật thất bại (mã \(proc.terminationStatus))"
                        ])
                    }

                    let candidateApp = URL(fileURLWithPath: extractDirPath).appendingPathComponent("BarFlow.app")
                    let binaryPath = candidateApp.appendingPathComponent("Contents/MacOS/BarFlow").path
                    guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
                        throw NSError(domain: "BarFlowUpdate", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "Không tìm thấy BarFlow.app hợp lệ trong gói tải về"
                        ])
                    }
                    continuation.resume(returning: candidateApp)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func spawnDetachedSwapAndRelaunch(
        oldPID: pid_t,
        extractedAppPath: String,
        targetAppPath: String,
        stageDirPath: String
    ) throws {
        let script = """
        OLD_PID="$1"
        SRC_APP="$2"
        DST_APP="$3"
        STAGE_DIR="$4"
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.2
        done
        rm -rf "$DST_APP"
        /usr/bin/ditto --noextattr "$SRC_APP" "$DST_APP"
        /usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
        /usr/bin/open "$DST_APP"
        rm -rf "$STAGE_DIR"
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proc.arguments = [
            "/bin/sh",
            "-c",
            script,
            "barflow-updater",
            "\(oldPID)",
            extractedAppPath,
            targetAppPath,
            stageDirPath
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    nonisolated private static func cleanVersionString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = cleanVersionString(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let rhs = cleanVersionString(current).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }
}
