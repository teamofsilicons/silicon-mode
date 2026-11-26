import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Observation
import os
import SiliconModeKit

/// Agent profile photos (today: a Silicon's Iris default photo), cached in memory and on disk.
///
/// - `image(for:)` reads memory, then the disk cache. It never touches the network, so the overlay
///   and the lock screen can call it from `body`.
/// - `prefetch(_:)` fetches missing or stale photos (older than 24 h) in the background. The app
///   calls it on every agent snapshot change, while the Mac is in normal use.
/// - Only https URLs on `AgentIdentity.avatarHosts` are fetched (redirects too), with an ephemeral
///   session (no cookies, no cache), a 10 s timeout and a 2 MB cap. Images are downsampled to
///   256 px and stored as PNG in `~/Library/Caches/ai.tos.mode/avatars/<sha256(url)>.png`.
/// - Custom uploaded photos need an authenticated Accounts lookup and are out of scope: a Silicon
///   with an upload still shows its Iris default.
/// - No network in `--snapshot` renders.
@MainActor @Observable
final class AvatarStore {
    /// Bumps when a photo arrives (views reading `image(for:)` re-render).
    private(set) var revision = 0

    @ObservationIgnored private var memory: [String: NSImage] = [:]
    /// Keys whose disk file was looked for and isn't there (until a fetch writes one).
    @ObservationIgnored private var missingOnDisk: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Last fetch attempt per key (successful or not), to space retries.
    @ObservationIgnored private var lastAttempt: [String: Date] = [:]

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let allowNetwork: Bool

    nonisolated static let maxBytes = 2 << 20
    nonisolated static let pixelSize = 256
    nonisolated static let refreshAfter: TimeInterval = 24 * 3600
    nonisolated static let retryAfter: TimeInterval = 10 * 60
    nonisolated private static let log = Logger(subsystem: "ai.tos.mode", category: "avatars")

    init(directory: URL = AvatarStore.defaultDirectory, allowNetwork: Bool = !SnapshotHarness.isRendering) {
        self.directory = directory
        self.allowNetwork = allowNetwork
    }

    nonisolated static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("ai.tos.mode/avatars", isDirectory: true)
    }

    /// The cached photo for `identity`, or nil (draw a monogram). Memory, then disk; never network.
    func image(for identity: AgentIdentity) -> NSImage? {
        _ = revision   // observe arrivals
        guard let url = identity.allowedAvatarURL else { return nil }
        let key = Self.key(for: url)
        if let img = memory[key] { return img }
        guard !missingOnDisk.contains(key) else { return nil }
        let file = fileURL(key)
        if let img = NSImage(contentsOf: file), img.isValid {
            memory[key] = img
            return img
        }
        missingOnDisk.insert(key)
        return nil
    }

    /// Fetches photos that aren't cached yet, or whose cache is older than a day. Cheap when there is
    /// nothing to do.
    func prefetch(_ identities: [AgentIdentity]) {
        guard allowNetwork else { return }
        let now = Date()
        var seen = Set<String>()
        for identity in identities {
            guard let url = identity.allowedAvatarURL else { continue }
            let key = Self.key(for: url)
            guard seen.insert(key).inserted, !inFlight.contains(key) else { continue }
            if let last = lastAttempt[key], now.timeIntervalSince(last) < Self.retryAfter { continue }
            if let age = cacheAge(key), age < Self.refreshAfter {
                lastAttempt[key] = now   // fresh: don't stat it again for a while
                continue
            }
            inFlight.insert(key)
            lastAttempt[key] = now
            let file = fileURL(key)
            let dir = directory
            Task.detached(priority: .utility) {
                let png = await Self.download(url)
                if let png { Self.write(png, to: file, in: dir) }
                await MainActor.run { self.finished(key, png: png) }
            }
        }
    }

    // MARK: Internals

    private func finished(_ key: String, png: Data?) {
        inFlight.remove(key)
        guard let png, let img = NSImage(data: png), img.isValid else { return }
        memory[key] = img
        missingOnDisk.remove(key)
        revision &+= 1
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).png") }

    private func cacheAge(_ key: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(key).path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }

    nonisolated static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func write(_ png: Data, to file: URL, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
    }

    // MARK: Network (off the main actor)

    nonisolated private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// Downloads `url` and returns it downsampled to `pixelSize` as PNG, or nil.
    nonisolated static func download(_ url: URL) async -> Data? {
        guard isAllowed(url) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("image/png,image/jpeg,image/webp,image/gif;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, isAllowed(finalURL) else { return nil }
            if http.expectedContentLength > Int64(maxBytes) { return nil }
            if let type = http.mimeType, !type.hasPrefix("image/") { return nil }
            var data = Data()
            data.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(maxBytes)))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return downsampledPNG(data)
        } catch {
            log.info("avatar fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return AgentIdentity.avatarHosts.contains(host)
    }

    /// Decodes any image ImageIO knows and re-encodes it as a ≤ 256 px PNG (never the original bytes).
    nonisolated static func downsampledPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Follows a redirect only to another allowed https host.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, AvatarStore.isAllowed(url) else { return nil }
        return request
    }
}
