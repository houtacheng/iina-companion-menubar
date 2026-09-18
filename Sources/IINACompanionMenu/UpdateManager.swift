import AppKit
import CryptoKit
import Foundation

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)
    case downloading(Double)
    case installing
    case failed
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    @Published var state: UpdateState = .idle
    @Published var errorMessage: String?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.2"

    private let releasesURL = URL(string: "https://api.github.com/repos/houtacheng/iina-companion-menubar/releases/latest")!
    private var release: GitHubRelease?
    private var checkedAutomatically = false

    func checkAutomatically() {
        guard !checkedAutomatically else { return }
        checkedAutomatically = true
        checkForUpdates(silent: true)
    }

    func checkForUpdates() { checkForUpdates(silent: false) }

    func downloadAndInstall() {
        guard let release,
              let archive = release.assets.first(where: {
                  $0.name.hasSuffix(".zip") && $0.name.localizedCaseInsensitiveContains("Menu")
              }),
              let checksum = release.assets.first(where: { $0.name == archive.name + ".sha256" }) else {
            errorMessage = "更新檔或 SHA-256 驗證檔不存在。"
            state = .failed
            return
        }

        state = .downloading(0)
        errorMessage = nil
        Task {
            do {
                async let archiveResult = URLSession.shared.data(from: archive.browserDownloadURL)
                async let checksumResult = URLSession.shared.data(from: checksum.browserDownloadURL)
                let ((archiveData, archiveResponse), (checksumData, checksumResponse)) = try await (archiveResult, checksumResult)
                try validateHTTP(archiveResponse)
                try validateHTTP(checksumResponse)
                state = .downloading(1)

                guard let expected = String(data: checksumData, encoding: .utf8)?
                    .split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
                      !expected.isEmpty else {
                    throw UpdateError.invalidChecksum
                }
                let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw UpdateError.checksumMismatch
                }

                state = .installing
                try install(archiveData)
            } catch {
                state = .failed
                errorMessage = readable(error)
            }
        }
    }

    private func checkForUpdates(silent: Bool) {
        guard state != .checking else { return }
        state = .checking
        if !silent { errorMessage = nil }

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("IINA-Companion-Menu/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try validateHTTP(response)
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                self.release = release
                let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                state = isNewer(version, than: currentVersion) ? .available(version) : .upToDate
                if !silent && state == .upToDate { errorMessage = "目前已是最新版本。" }
            } catch {
                state = silent ? .idle : .failed
                if !silent { errorMessage = readable(error) }
            }
        }
    }

    private func install(_ archiveData: Data) throws {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("IINACompanionUpdate-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("update.zip")
        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try archiveData.write(to: archiveURL, options: .atomic)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archiveURL.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.extractionFailed }

        guard let enumerator = fileManager.enumerator(at: extracted, includingPropertiesForKeys: nil),
              let newApp = enumerator.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let bundle = Bundle(url: newApp)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApplication }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", newApp.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.invalidSignature }

        let destination = Bundle.main.bundleURL
        let backup = temporary.appendingPathComponent("previous.app")
        do {
            try fileManager.moveItem(at: destination, to: backup)
            try fileManager.moveItem(at: newApp, to: destination)
        } catch {
            if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw UpdateError.installPermission
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            NSApplication.shared.terminate(nil)
        }
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw UpdateError.serverUnavailable
        }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private func readable(_ error: Error) -> String {
        switch error {
        case UpdateError.serverUnavailable: return "目前無法取得更新資訊。"
        case UpdateError.invalidChecksum: return "更新驗證檔格式不正確。"
        case UpdateError.checksumMismatch: return "更新檔驗證失敗，已取消安裝。"
        case UpdateError.extractionFailed: return "無法解壓縮更新檔。"
        case UpdateError.appNotFound: return "更新檔中找不到 App。"
        case UpdateError.wrongApplication: return "更新檔不是 IINA Companion Menu。"
        case UpdateError.invalidSignature: return "更新程式碼簽章無效。"
        case UpdateError.installPermission: return "沒有權限更新目前位置，請將 App 移到「應用程式」後再試。"
        default: return "檢查更新失敗：\(error.localizedDescription)"
        }
    }
}

private enum UpdateError: Error {
    case serverUnavailable
    case invalidChecksum
    case checksumMismatch
    case extractionFailed
    case appNotFound
    case wrongApplication
    case invalidSignature
    case installPermission
}
