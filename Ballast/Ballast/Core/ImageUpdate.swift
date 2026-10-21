import Foundation

/// What a registry currently has under a container's image tag.
struct RemoteImage: Equatable, Sendable {
    /// What the tag points at now — for a multi-arch image, the index digest,
    /// which is also what Docker records in `RepoDigests` on pull.
    var digest: String
    /// Another tag naming the same digest that reads as a version, e.g.
    /// `4.0.20.3014-ls1` for LinuxServer's `latest`. Only looked up when the
    /// digest differs from what's running.
    var versionTag: String?
}

/// Whether a container is running the image its tag points at now.
enum ImageUpdateStatus: Equatable, Sendable {
    case upToDate
    /// The registry's image is a different release of the app.
    case newVersion(running: String?, available: String)
    /// The same release, rebuilt. LinuxServer rebuilds every image about
    /// weekly for base-image patches (`-ls250` → `-ls251`), which is worth
    /// knowing about but not worth an icon.
    case rebuild(available: String)
    /// The registry has a different image and nothing names its version.
    case newImage
    /// Nothing to compare: pinned by digest, built locally, a private image,
    /// or the registry didn't answer.
    case unavailable(reason: String)

    /// Rebuilds deliberately don't count: a release is what you'd go and
    /// read about.
    var isUpdate: Bool {
        switch self {
        case .newVersion, .newImage: true
        case .upToDate, .rebuild, .unavailable: false
        }
    }

    /// One line for a tooltip.
    var summary: String {
        switch self {
        case .upToDate:
            "Image is up to date"
        case .newVersion(let running, let available):
            if let running {
                "Version \(ImageUpdateResolver.appVersion(available)) available — running \(ImageUpdateResolver.appVersion(running))"
            } else {
                "Version \(ImageUpdateResolver.appVersion(available)) available"
            }
        case .rebuild(let available):
            "Rebuilt image available (\(available)), same version"
        case .newImage:
            "Newer image available"
        case .unavailable(let reason):
            "Can't check for updates: \(reason)"
        }
    }
}

enum ImageUpdateResolver {
    /// Compares what's running with what the registry has.
    ///
    /// The digest decides whether anything changed at all; versions only
    /// decide how to describe it. An unrecognisable version can therefore
    /// only ever turn a rebuild into an update, never hide a real one.
    static func status(
        localDigests: [String],
        remote: RemoteImage,
        runningVersion: String?
    ) -> ImageUpdateStatus {
        guard !localDigests.isEmpty else {
            return .unavailable(reason: "built locally, so no registry digest")
        }
        if localDigests.contains(remote.digest) { return .upToDate }

        guard let available = remote.versionTag else { return .newImage }
        if let runningVersion, appVersion(runningVersion) == appVersion(available) {
            return .rebuild(available: available)
        }
        return .newVersion(running: runningVersion, available: available)
    }

    /// The app's own version, with packaging stripped:
    /// `4.0.20.3014-ls1` → `4.0.20.3014`, `version-4.0.20.3014` → `4.0.20.3014`,
    /// `v1.2.3` → `1.2.3`.
    static func appVersion(_ version: String) -> String {
        var result = version.trimmingCharacters(in: .whitespaces).lowercased()
        result.replace(/-ls\d+$/, with: "")
        // Channel prefixes LinuxServer puts on tags: `version-`, `develop-`, `nightly-`.
        result.replace(/^(?:[a-z]+-)+(?=\d|v\d)/, with: "")
        if result.hasPrefix("v"), result.dropFirst().first?.isNumber == true {
            result.removeFirst()
        }
        return result
    }

    private static let architecturePrefixes = [
        "amd64-", "arm64v8-", "arm64-", "arm32v7-", "arm32v6-", "armhf-", "i386-", "ppc64le-", "s390x-", "riscv64-",
    ]

    /// Picks the tag that best names `digest`, from a registry's tag list.
    ///
    /// LinuxServer's `-lsNNN` tags win, because they carry the build number
    /// that tells a rebuild from a release. Otherwise a plain version over a
    /// variant (`7.4.11` over `7.4.11-bookworm`), then the most specific —
    /// `10.9.11` over `10.9` over `10`.
    static func versionTag(among tags: [(name: String, digest: String?)], matching digest: String) -> String? {
        let candidates = tags
            .filter { $0.digest == digest }
            .map(\.name)
            .filter { name in
                let lower = name.lowercased()
                return lower.contains(where: \.isNumber)
                    && !Container.channelTags.contains(lower)
                    && !architecturePrefixes.contains { lower.hasPrefix($0) }
            }

        let linuxServer = candidates.filter { $0.contains(/-ls\d+$/) }
        if let best = linuxServer.min(by: { ($0.count, $0) < ($1.count, $1) }) { return best }

        func rank(_ tag: String) -> (Int, Int, String) {
            let version = appVersion(tag)
            return (version.wholeMatch(of: /\d+(\.\d+)*/) == nil ? 0 : 1, version.count, tag)
        }
        return candidates.max { rank($0) < rank($1) }
    }
}

extension Container {
    /// The version of what's actually running, for comparing with the
    /// registry. The image's own label first — on `:latest` it's the only
    /// thing that knows — then LinuxServer's older label, then the tag.
    var runningImageVersion: String? {
        if let labelled = labels["org.opencontainers.image.version"], !labelled.isEmpty,
           !Self.channelTags.contains(labelled.lowercased()) {
            return labelled
        }
        // "Linuxserver.io version:- 4.0.20.3014-ls1 Build-date:- 2026-10-20T19:02:49+00:00"
        if let build = labels["build_version"],
           let match = build.firstMatch(of: /version:-\s*(\S+)/) {
            return String(match.1)
        }
        if let tag = imageTag, !Self.channelTags.contains(tag.lowercased()) { return tag }
        return nil
    }
}
