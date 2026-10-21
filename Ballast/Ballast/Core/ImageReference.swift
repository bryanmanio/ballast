import Foundation

/// An image reference split into the parts a registry is asked about:
/// `lscr.io/linuxserver/sonarr:latest` → `lscr.io`, `linuxserver/sonarr`,
/// `latest`.
struct ImageReference: Hashable, Sendable {
    /// Host serving the v2 API. Docker Hub's is `registry-1.docker.io`, not
    /// the `docker.io` people write.
    var registry: String
    /// Docker Hub's official images live under `library/`, which nobody writes.
    var repository: String
    var tag: String

    static let dockerHubRegistry = "registry-1.docker.io"
    private static let dockerHubAliases: Set<String> = ["docker.io", "index.docker.io", dockerHubRegistry]

    /// Nil for a reference pinned by digest: it can't move, so there is
    /// never anything newer to find.
    init?(_ reference: String) {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, !reference.contains("@") else { return nil }

        var components = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // The first component is a host only if it looks like one — Docker's
        // own rule. `linuxserver/sonarr` is a Hub repository, not a host.
        var registry = Self.dockerHubRegistry
        if components.count > 1,
           let first = components.first,
           first.contains(".") || first.contains(":") || first == "localhost" {
            registry = Self.dockerHubAliases.contains(first) ? Self.dockerHubRegistry : first
            components.removeFirst()
        }

        // With the host gone, a colon can only be the tag separator.
        var path = components.joined(separator: "/")
        var tag = "latest"
        if let colon = path.lastIndex(of: ":") {
            tag = String(path[path.index(after: colon)...])
            path = String(path[..<colon])
        }
        guard !path.isEmpty, !tag.isEmpty else { return nil }

        if registry == Self.dockerHubRegistry && !path.contains("/") {
            path = "library/" + path
        }

        self.registry = registry
        self.repository = path
        self.tag = tag
    }

    var isDockerHub: Bool { registry == Self.dockerHubRegistry }

    /// LinuxServer publishes the same images, with the same digests, to
    /// Docker Hub, GitHub and its own `lscr.io` front for GitHub.
    var isLinuxServer: Bool {
        repository.hasPrefix("linuxserver/")
            && (isDockerHub || registry == "lscr.io" || registry == "ghcr.io")
    }

    /// The Docker Hub repository whose tag list can name a digest's version.
    /// LinuxServer images are looked up there whichever registry they were
    /// pulled from, since the digests match.
    var hubRepository: String? {
        isDockerHub || isLinuxServer ? repository : nil
    }

    /// Where to read about the image's releases. Docker Hub's tag list for
    /// anything it hosts — including LinuxServer images pulled from
    /// elsewhere — and GitHub's package page for ghcr.io.
    var webURL: URL? {
        if let hubRepository {
            if hubRepository.hasPrefix("library/") {
                return URL(string: "https://hub.docker.com/_/\(hubRepository.dropFirst("library/".count))/tags")
            }
            return URL(string: "https://hub.docker.com/r/\(hubRepository)/tags")
        }
        // ghcr.io redirects a repository path to its GitHub package page.
        if registry == "ghcr.io" || registry == "lscr.io" {
            return URL(string: "https://ghcr.io/\(repository)")
        }
        return nil
    }

    /// Short name for where the link goes, for menu items.
    var webSiteName: String? {
        if hubRepository != nil { return "Docker Hub" }
        if webURL != nil { return "GitHub" }
        return nil
    }
}
