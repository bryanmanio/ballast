import Foundation

/// A dotted version number, as written in a release tag or the bundle's
/// `CFBundleShortVersionString`. Compared numerically, so 1.10 is newer than
/// 1.9, and missing components count as zero, so 1.2 and 1.2.0 are the same.
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let components: [Int]

    /// Accepts a leading `v`, which is how the release tags are written.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        self.components = components
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Without the trailing zeros that don't change what the version means.
    private var significant: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.significant == rhs.significant
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(significant)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// A published release of Ballast.
struct AppRelease: Equatable, Sendable {
    let version: AppVersion
    let name: String
    /// The release's page on GitHub, which carries the notes and the DMG.
    let pageURL: URL
    let publishedAt: Date?
}

enum AppUpdateError: Error, Equatable, Sendable {
    case network(String)
    case badResponse(statusCode: Int)
    case unreadable

    var hint: String {
        switch self {
        case .network(let detail): "Couldn't reach GitHub: \(detail)"
        case .badResponse(let code): "GitHub answered \(code). Try again later."
        case .unreadable: "GitHub's answer didn't name a version."
        }
    }
}

/// Asks where the newest release of Ballast is.
protocol AppUpdateChecking: Sendable {
    func latestRelease() async throws(AppUpdateError) -> AppRelease
}

/// Reads GitHub's "latest release", which already leaves out drafts and
/// pre-releases. Anonymous: the API allows 60 requests an hour per address,
/// and this makes one a day.
struct GitHubReleaseChecker: AppUpdateChecking {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/bryanmanio/ballast/releases/latest")!

    private let session: URLSession

    init(currentVersion: String = AppUpdater.bundleVersion, timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Ballast/\(currentVersion)",
        ]
        session = URLSession(configuration: configuration)
    }

    func latestRelease() async throws(AppUpdateError) -> AppRelease {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: Self.latestReleaseURL)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        guard http.statusCode == 200 else { throw .badResponse(statusCode: http.statusCode) }
        return try Self.decode(data)
    }

    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let html_url: URL
        let published_at: Date?
    }

    static func decode(_ data: Data) throws(AppUpdateError) -> AppRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              let version = AppVersion(payload.tag_name)
        else { throw .unreadable }
        return AppRelease(
            version: version,
            name: payload.name ?? "Ballast \(version)",
            pageURL: payload.html_url,
            publishedAt: payload.published_at
        )
    }
}

/// Never finds anything. For tests and previews, which shouldn't touch the network.
struct DisabledAppUpdateChecker: AppUpdateChecking {
    func latestRelease() async throws(AppUpdateError) -> AppRelease {
        throw .network("update checks are disabled")
    }
}

/// Always has a newer version, so fixture mode can show every piece of the
/// update UI without a real release to point at.
struct FixtureAppUpdateChecker: AppUpdateChecking {
    func latestRelease() async throws(AppUpdateError) -> AppRelease {
        AppRelease(
            version: AppVersion("99.0")!,
            name: "Ballast 99.0",
            pageURL: URL(string: "https://github.com/bryanmanio/ballast/releases")!,
            publishedAt: Date()
        )
    }
}
