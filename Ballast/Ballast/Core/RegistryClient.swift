import Foundation

enum RegistryError: Error, Equatable, Sendable {
    /// A private image, or a registry that wants credentials Ballast doesn't have.
    case unauthorized
    case notFound
    case badResponse(statusCode: Int)
    case noDigest
    case network(String)

    var reason: String {
        switch self {
        case .unauthorized: "the registry wants a login"
        case .notFound: "the registry doesn't have this tag"
        case .badResponse(let code): "the registry answered \(code)"
        case .noDigest: "the registry didn't say which image the tag points at"
        case .network(let detail): detail
        }
    }
}

/// Asks image registries what a tag points at.
protocol ImageRegistry: Sendable {
    /// The digest the tag points at now.
    func digest(for reference: ImageReference) async throws(RegistryError) -> String
    /// A tag naming the same image as `digest` that reads as a version, if
    /// the registry can say. Never throws: a missing name only makes the
    /// description vaguer.
    func versionTag(for reference: ImageReference, digest: String) async -> String?
}

extension ImageRegistry {
    /// Looks up every reference, a few at a time, naming the version only
    /// where the digest isn't one already running.
    func lookUp(
        _ localDigests: [ImageReference: Set<String>],
        maxConcurrent: Int = 4
    ) async -> [ImageReference: Result<RemoteImage, RegistryError>] {
        var results: [ImageReference: Result<RemoteImage, RegistryError>] = [:]

        // Same hand-rolled throttle as `ServiceProbe`: thirty images at once
        // is a burst a registry is entitled to refuse.
        await withTaskGroup(of: (ImageReference, Result<RemoteImage, RegistryError>).self) { group in
            let pending = Array(localDigests)
            var index = 0

            func addNext() {
                guard index < pending.count else { return }
                let (reference, local) = pending[index]
                index += 1
                group.addTask {
                    do {
                        let digest = try await self.digest(for: reference)
                        let version = local.contains(digest)
                            ? nil
                            : await self.versionTag(for: reference, digest: digest)
                        return (reference, .success(RemoteImage(digest: digest, versionTag: version)))
                    } catch let error as RegistryError {
                        return (reference, .failure(error))
                    } catch {
                        return (reference, .failure(.network(error.localizedDescription)))
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, pending.count) { addNext() }
            while let (reference, result) = await group.next() {
                results[reference] = result
                addNext()
            }
        }
        return results
    }
}

/// Speaks the registry v2 API anonymously, which is all public images need.
///
/// Only `HEAD` requests go to the registry: Docker Hub doesn't count those
/// against its pull rate limit, and the digest is in the response headers.
/// Versions are named from Docker Hub's own tag list, which is the source of
/// truth for LinuxServer images whichever registry they were pulled from.
struct RegistryClient: ImageRegistry {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Ballast/1.0 (update check)"]
        session = URLSession(configuration: configuration)
    }

    /// Index types first, so a multi-arch image answers with the digest of
    /// the index — the one `RepoDigests` records — not of one platform.
    private static let manifestTypes = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ].joined(separator: ", ")

    func digest(for reference: ImageReference) async throws(RegistryError) -> String {
        guard let url = URL(string: "https://\(reference.registry)/v2/\(reference.repository)/manifests/\(reference.tag)") else {
            throw .notFound
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(Self.manifestTypes, forHTTPHeaderField: "Accept")

        var response = try await send(request)
        // Every public registry still wants a token, just not a login: the
        // 401 says where to get one.
        if response.statusCode == 401 {
            guard let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate"),
                  let token = try await token(for: challenge, repository: reference.repository) else {
                throw .unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            response = try await send(request)
        }

        switch response.statusCode {
        case 200: break
        case 401, 403: throw .unauthorized
        case 404: throw .notFound
        default: throw .badResponse(statusCode: response.statusCode)
        }
        guard let digest = response.value(forHTTPHeaderField: "Docker-Content-Digest"), !digest.isEmpty else {
            throw .noDigest
        }
        return digest
    }

    func versionTag(for reference: ImageReference, digest: String) async -> String? {
        guard let repository = reference.hubRepository else { return nil }
        let parts = repository.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        var components = URLComponents(string: "https://hub.docker.com/v2/namespaces/\(parts[0])/repositories/\(parts[1])/tags")
        // Newest first, so the tags sharing the current digest are on the
        // first page.
        components?.queryItems = [
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "ordering", value: "last_updated"),
        ]
        guard let url = components?.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(HubTagPage.self, from: data) else {
            return nil
        }
        return ImageUpdateResolver.versionTag(
            among: page.results.map { ($0.name, $0.digest) },
            matching: digest
        )
    }

    // MARK: - Internals

    private func send(_ request: URLRequest) async throws(RegistryError) -> HTTPURLResponse {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RegistryError.noDigest }
            return http
        } catch let error as RegistryError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    /// Follows a `Bearer realm="…",service="…",scope="…"` challenge to an
    /// anonymous pull token.
    private func token(for challenge: String, repository: String) async throws(RegistryError) -> String? {
        let parameters = Self.challengeParameters(challenge)
        guard let realm = parameters["realm"], var components = URLComponents(string: realm) else { return nil }
        var items: [URLQueryItem] = []
        if let service = parameters["service"] { items.append(URLQueryItem(name: "service", value: service)) }
        items.append(URLQueryItem(name: "scope", value: parameters["scope"] ?? "repository:\(repository):pull"))
        components.queryItems = items
        guard let url = components.url else { return nil }

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw .network(error.localizedDescription)
        }
        let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        return response?.token ?? response?.access_token
    }

    static func challengeParameters(_ challenge: String) -> [String: String] {
        guard challenge.lowercased().hasPrefix("bearer ") else { return [:] }
        var result: [String: String] = [:]
        for match in challenge.dropFirst("bearer ".count).matches(of: /(\w+)="([^"]*)"/) {
            result[String(match.1).lowercased()] = String(match.2)
        }
        return result
    }

    private struct TokenResponse: Decodable {
        var token: String?
        var access_token: String?
    }

    private struct HubTagPage: Decodable {
        var results: [HubTag]
    }

    private struct HubTag: Decodable {
        var name: String
        var digest: String?
    }
}

/// Canned registry answers, so fixture mode shows every update state without
/// touching the network.
struct FixtureImageRegistry: ImageRegistry {
    func digest(for reference: ImageReference) async throws(RegistryError) -> String {
        if let tag = FixtureContainerSource.remoteTags[reference.repository] {
            return "sha256:\(reference.repository)-\(tag ?? "new")"
        }
        if reference.registry == "registry.example.com" { throw .unauthorized }
        return FixtureContainerSource.localDigest(for: reference.repository)
    }

    func versionTag(for reference: ImageReference, digest: String) async -> String? {
        FixtureContainerSource.remoteTags[reference.repository] ?? nil
    }
}

/// For a store that shouldn't touch the network: tests and previews.
struct DisabledImageRegistry: ImageRegistry {
    func digest(for reference: ImageReference) async throws(RegistryError) -> String {
        throw .network("update checks are disabled")
    }

    func versionTag(for reference: ImageReference, digest: String) async -> String? { nil }
}
