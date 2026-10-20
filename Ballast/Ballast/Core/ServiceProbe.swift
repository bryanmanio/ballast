import Foundation

protocol ServiceProbing: Sendable {
    func probe(_ targets: [String: URL]) async -> [String: ProbeOutcome]
}

/// Asks each service's own URL whether it is answering.
///
/// This is the half of the status signal Docker can't give us: a container can
/// be running, and even pass its healthcheck, while the thing inside it has
/// stopped serving. Any HTTP response at all counts as alive — a 401 or a 500
/// still proves something is listening.
struct ServiceProbe: ServiceProbing {
    var timeout: Duration = .milliseconds(2500)
    var maxConcurrent = 6

    func probe(_ targets: [String: URL]) async -> [String: ProbeOutcome] {
        guard !targets.isEmpty else { return [:] }

        let session = URLSession(configuration: Self.configuration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }

        var results: [String: ProbeOutcome] = [:]
        results.reserveCapacity(targets.count)

        // Hand-rolled throttle: thirty services starting at once would make
        // a visible spike on both the Mac and the NAS every refresh.
        await withTaskGroup(of: (String, ProbeOutcome).self) { group in
            let pending = Array(targets)
            var index = 0

            func addNext() {
                guard index < pending.count else { return }
                let (id, url) = pending[index]
                index += 1
                group.addTask { (id, await Self.probeOne(url, session: session)) }
            }

            for _ in 0..<min(maxConcurrent, pending.count) { addNext() }
            while let (id, outcome) = await group.next() {
                results[id] = outcome
                addNext()
            }
        }

        return results
    }

    private static func configuration(timeout: Duration) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Ballast/1.0 (status probe)"]
        return configuration
    }

    private static func probeOne(_ url: URL, session: URLSession) async -> ProbeOutcome {
        var request = URLRequest(url: url)
        // GET rather than HEAD: plenty of self-hosted apps answer HEAD with
        // 405 or simply hang on it.
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .responded(statusCode: code)
        } catch {
            return classify(error)
        }
    }

    static func classify(_ error: Error) -> ProbeOutcome {
        let urlError = error as? URLError
        switch urlError?.code {
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost:
            return .refused
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed, .clientCertificateRejected:
            // Reaching a TLS error means something completed a TCP handshake
            // and spoke TLS back, which is all we were asking.
            return .tlsUntrusted
        case .cannotFindHost, .dnsLookupFailed:
            return .failed("host not found")
        case .notConnectedToInternet, .networkConnectionLost:
            return .failed("network unavailable")
        case .some(let code):
            return .failed("URLError \(code.rawValue)")
        case nil:
            return .failed(error.localizedDescription)
        }
    }
}
