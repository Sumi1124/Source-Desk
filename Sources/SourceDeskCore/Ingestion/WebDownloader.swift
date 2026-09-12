import Foundation

/// Downloads pages from the web.
///
/// Everything about this type exists to fail *well*: a research tool has to survive
/// a 404, a paywall, a redirect loop, a 40 MB page and a site that asks robots to
/// stay out, and then explain which of those happened. It never attempts to defeat
/// an access control: a sign-in wall is reported as a sign-in wall.
public struct WebDownloader: Sendable {

    public struct Options: Sendable {
        /// Pages larger than this are refused with an actionable message rather than
        /// being truncated silently.
        public var maximumBytes: Int64
        public var timeout: TimeInterval
        /// Whether robots.txt is consulted. On by default; only ever turned off by
        /// the user for their own intranet.
        public var respectRobotsTxt: Bool
        public var maximumRedirects: Int
        /// Only text-like content types are accepted; a PDF URL is handed to the
        /// document importer instead.
        public var allowedContentTypes: [String]

        public init(
            maximumBytes: Int64 = 25 * 1024 * 1024,
            timeout: TimeInterval = 30,
            respectRobotsTxt: Bool = true,
            maximumRedirects: Int = 10,
            allowedContentTypes: [String] = [
                "text/html", "text/plain", "application/xhtml+xml", "text/markdown",
                "application/xml", "text/xml", "application/json", "text/rtf"
            ]
        ) {
            self.maximumBytes = maximumBytes
            self.timeout = timeout
            self.respectRobotsTxt = respectRobotsTxt
            self.maximumRedirects = maximumRedirects
            self.allowedContentTypes = allowedContentTypes
        }
    }

    public struct Response: Sendable {
        public var finalURL: String
        public var statusCode: Int
        public var contentType: String?
        public var html: String
        public var readableText: String?
        public var title: String?
        public var publishedAt: Date?
        public var byteCount: Int64
        public var elapsedMilliseconds: Int
        public var redirectChain: [String]
        /// True when the site refused automated access (403, paywall markers), so
        /// the caller can explain it in those terms.
        public var blockedReason: String?
    }

    public enum RobotsPolicy: Sendable {
        case allowed
        case disallowed(rule: String)
        case unavailable
    }

    let options: Options
    private let session: URLSession
    /// In-memory robots.txt cache, per host, for the lifetime of the process.
    private let robotsCache = RobotsCache()

    public init(options: Options = Options()) {
        self.options = options
        self.session = HTTPClient.session(timeout: options.timeout)
    }

    // MARK: Fetching

    public func fetch(url rawURL: String, maximumBytes: Int64? = nil) async throws -> Response {
        let started = Date()
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else {
            throw SourceDeskError.invalidURL(rawURL)
        }
        guard scheme == "http" || scheme == "https" else {
            throw SourceDeskError.notHTTPURL(rawURL)
        }
        guard url.host() != nil else { throw SourceDeskError.invalidURL(rawURL) }

        // Some services publish API/JSON documentation as a data URL; guard against
        // obviously un-fetchable input early with a clear message.
        if url.host()?.lowercased() == "localhost" || url.host()?.lowercased() == "127.0.0.1" {
            // Local pages are legitimate (an intranet wiki), so this is allowed —
            // the check only ensures we do not treat a bare host as a search box.
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = options.timeout
        request.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let limit = maximumBytes ?? options.maximumBytes

        var redirects: [String] = []
        var currentURL = url
        var currentRequest = request
        var responseData = Data()
        var finalResponse: HTTPURLResponse?

        for hop in 0...options.maximumRedirects {
            if options.respectRobotsTxt {
                let decision = await robotsDecision(for: currentURL)
                if case .disallowed(let rule) = decision {
                    throw SourceDeskError.robotsDisallowed(url: currentURL.absoluteString)
                        .withNote(rule)
                }
            }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: currentRequest)
            } catch {
                var mapped = HTTPClient.mapError(error, provider: "the website", url: currentURL)
                if case .requestTimedOut = mapped {
                    mapped = .requestTimedOut(url: currentURL.absoluteString, seconds: options.timeout)
                }
                throw mapped
            }
            guard let http = response as? HTTPURLResponse else {
                throw SourceDeskError.downloadFailed(url: currentURL.absoluteString, reason: "no HTTP response")
            }

            if let location = http.value(forHTTPHeaderField: "Location"),
               (300..<400).contains(http.statusCode),
               let next = URL(string: location, relativeTo: currentURL) {
                redirects.append(next.absoluteString)
                currentURL = next.absoluteURL
                currentRequest = URLRequest(url: currentURL)
                currentRequest.timeoutInterval = options.timeout
                currentRequest.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
                currentRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
                if hop == options.maximumRedirects {
                    throw SourceDeskError.downloadFailed(url: url.absoluteString, reason: "too many redirects (more than \(options.maximumRedirects))")
                }
                continue
            }
            responseData = data
            finalResponse = http
            break
        }

        guard let http = finalResponse else {
            throw SourceDeskError.downloadFailed(url: url.absoluteString, reason: "the server never returned a response")
        }

        // Content-Length is advisory; a server can lie, so the real byte count is
        // checked too (after the fact, to avoid downloading gigabytes first).
        if let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), declared > limit {
            throw SourceDeskError.pageTooLarge(url: currentURL.absoluteString, bytes: declared, limitBytes: limit)
        }
        if Int64(responseData.count) > limit {
            throw SourceDeskError.pageTooLarge(url: currentURL.absoluteString, bytes: Int64(responseData.count), limitBytes: limit)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()

        var blockedReason: String?
        switch http.statusCode {
        case 200...299:
            break
        case 401, 407:
            throw SourceDeskError.authenticationRequired(url: currentURL.absoluteString)
        case 403:
            blockedReason = "the site returned HTTP 403, which usually means automated access is refused"
        case 404:
            throw SourceDeskError.httpStatus(url: currentURL.absoluteString, status: 404)
        case 429:
            throw SourceDeskError.httpStatus(url: currentURL.absoluteString, status: 429)
        case 451:
            throw SourceDeskError.httpStatus(url: currentURL.absoluteString, status: 451)
        case 500...599:
            throw SourceDeskError.httpStatus(url: currentURL.absoluteString, status: http.statusCode)
        default:
            if (300..<400).contains(http.statusCode) {
                throw SourceDeskError.downloadFailed(url: currentURL.absoluteString, reason: "the server kept redirecting without a final location")
            }
        }

        if let contentType, !contentType.isEmpty,
           !options.allowedContentTypes.contains(where: { contentType.contains($0) }) {
            if contentType.contains("application/pdf") {
                throw SourceDeskError.unsupportedDocument(name: currentURL.lastPathComponent.isEmpty ? "document.pdf" : currentURL.lastPathComponent,
                                                         detail: "This URL serves a PDF. Add it with “Add PDF…” so it is imported as a document.")
            }
            if contentType.contains("image") || contentType.contains("video") || contentType.contains("audio") {
                throw SourceDeskError.unsupportedDocument(name: currentURL.absoluteString,
                                                         detail: "This URL serves \(contentType), which has no readable text.")
            }
            if contentType.contains("application/zip") || contentType.contains("octet-stream") {
                throw SourceDeskError.unsupportedDocument(name: currentURL.absoluteString,
                                                         detail: "This URL serves a file download (\(contentType)) rather than a page.")
            }
        }

        let encoding = Self.detectEncoding(response: http, data: responseData)
        let body = String(data: responseData, encoding: encoding)
            ?? String(decoding: responseData, as: UTF8.self)

        // A paywall or sign-in gate often returns 200 with a short gate page.
        if blockedReason == nil, let gate = Self.detectAccessGate(html: body) {
            blockedReason = gate
        }

        var title: String?
        var publishedAt: Date?
        var readable: String?
        if body.contains("<") {
            if let document = try? HTMLExtractor.extract(html: body, url: currentURL.absoluteString) {
                title = document.title
                publishedAt = document.publishedAt
                readable = document.plainText
            }
        } else {
            title = currentURL.lastPathComponent.isEmpty ? currentURL.host() : currentURL.lastPathComponent
            readable = body
        }

        return Response(
            finalURL: currentURL.absoluteString,
            statusCode: http.statusCode,
            contentType: contentType,
            html: body,
            readableText: readable,
            title: title,
            publishedAt: publishedAt,
            byteCount: Int64(responseData.count),
            elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            redirectChain: redirects,
            blockedReason: blockedReason
        )
    }

    /// Parses a fetched page into a document, mapping extraction failures onto
    /// specific, actionable errors.
    public func extractDocument(from response: Response) throws -> ExtractedDocument {
        if let blocked = response.blockedReason {
            if blocked.contains("403") {
                throw SourceDeskError.downloadFailed(url: response.finalURL, reason: blocked)
            }
            if blocked.contains("sign") || blocked.contains("paywall") || blocked.contains("subscri") {
                throw SourceDeskError.authenticationRequired(url: response.finalURL)
            }
        }
        do {
            let document = try HTMLExtractor.extract(html: response.html, url: response.finalURL, fallbackTitle: response.title)
            return document
        } catch let failure as HTMLExtractor.Failure {
            switch failure {
            case .noReadableContent(let length):
                if length == 0, Self.looksClientRendered(html: response.html) {
                    throw SourceDeskError.javascriptOnlyPage(url: response.finalURL)
                }
                throw SourceDeskError.emptyExtraction(url: response.finalURL)
            }
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.malformedHTML(url: response.finalURL, detail: error.localizedDescription)
        }
    }

    // MARK: Robots

    public func robotsDecision(for url: URL) async -> RobotsPolicy {
        let (key, robotsURL) = Self.robotsLocation(for: url)
        guard let robotsURL else { return .unavailable }
        if let cached = robotsCache.value(for: key) { return cached.evaluate(path: url.path, userAgent: Networking.userAgent) }

        var rules = RobotsRules.empty
        var request = URLRequest(url: robotsURL)
        request.timeoutInterval = min(8, options.timeout)
        request.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            rules = RobotsRules(text: String(decoding: data.prefix(512_000), as: UTF8.self))
        }
        robotsCache.store(rules, for: key)
        return rules.evaluate(path: url.path, userAgent: Networking.userAgent)
    }

    /// robots.txt lives at the *origin*, which includes the port. Dropping the port
    /// would consult (and cache) the wrong file for any non-default port — a local
    /// development server, or an intranet wiki on :8080.
    static func robotsLocation(for url: URL) -> (key: String, robotsURL: URL?) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host() else { return ("", nil) }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return (origin, URL(string: "\(origin)/robots.txt"))
    }

    // MARK: Heuristics

    public static func detectEncoding(response: HTTPURLResponse, data: Data) -> String.Encoding {
        if let charset = response.value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: "charset=").last?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased() {
            switch charset {
            case "utf-8", "utf8": return .utf8
            case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
            case "windows-1252", "cp1252": return .windowsCP1252
            case "us-ascii", "ascii": return .ascii
            case "shift_jis", "sjis": return .shiftJIS
            case "euc-jp": return .japaneseEUC
            case "iso-2022-jp": return .iso2022JP
            case "utf-16", "utf16": return .utf16
            default: break
            }
        }
        // Sniff a meta charset from the first part of the document.
        let head = String(decoding: data.prefix(4_096), as: UTF8.self).lowercased()
        if head.contains("charset=shift_jis") || head.contains("charset=\"shift_jis\"") { return .shiftJIS }
        if head.contains("charset=iso-8859-1") { return .isoLatin1 }
        if head.contains("charset=windows-1252") { return .windowsCP1252 }
        return .utf8
    }

    /// Recognises the common sign-in and paywall gates that arrive with HTTP 200.
    public static func detectAccessGate(html: String) -> String? {
        let lowered = html.lowercased()
        let gates: [(needle: String, description: String)] = [
            ("enable javascript and cookies to continue", "the site requires JavaScript and cookies before showing content"),
            ("please sign in to continue", "the page asks visitors to sign in"),
            ("subscribe to read", "the page is behind a subscription paywall"),
            ("this content is subscriber", "the page is behind a subscription paywall"),
            ("create a free account to read", "the page asks visitors to create an account"),
            ("are you a robot", "the site is presenting a bot check"),
            ("verify you are human", "the site is presenting a bot check")
        ]
        for gate in gates where lowered.contains(gate.needle) {
            return gate.description
        }
        return nil
    }

    /// A page that carries a JS framework but almost no static text is client
    /// rendered: worth saying so rather than storing an empty source.
    public static func looksClientRendered(html: String) -> Bool {
        let lowered = html.lowercased()
        let frameworkMarkers = ["__next_data__", "id=\"root\"", "id=\"app\"", "ng-app", "data-reactroot", "window.__nuxt__", "ember-application"]
        let hasFramework = frameworkMarkers.contains { lowered.contains($0) }
        if !hasFramework {
            // Also treat a page consisting mostly of script tags as client-rendered.
            let scriptBytes = html.components(separatedBy: "<script").dropFirst().reduce(0) { $0 + $1.count }
            return scriptBytes > html.count / 2 && html.count > 2_000
        }
        let textWithoutMarkup = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return TextMath.wordCount(textWithoutMarkup) < 120
    }
}

private extension SourceDeskError {
    /// Attaches the specific robots rule to the error's reason, so the alert can
    /// quote the line that caused the refusal.
    func withNote(_ note: String) -> SourceDeskError {
        switch self {
        case .robotsDisallowed(let url):
            return .robotsDisallowed(url: "\(url) — disallowed by “\(note.prefix(80))”")
        default:
            return self
        }
    }
}

// MARK: - robots.txt

/// A parser for the `User-agent` / `Disallow` subset of robots.txt that matters
/// here. Groups for `User-agent: *` and for this app's own user agent are honoured;
/// the most specific matching rule wins, as the specification requires.
public struct RobotsRules: Sendable {

    public struct Rule: Sendable {
        public var path: String
        public var allow: Bool
        /// Longer rules are more specific.
        public var specificity: Int { path.count }
    }

    public var rules: [Rule]
    public var crawlDelay: TimeInterval?

    public static let empty = RobotsRules(rules: [], crawlDelay: nil)

    public init(rules: [Rule], crawlDelay: TimeInterval?) {
        self.rules = rules
        self.crawlDelay = crawlDelay
    }

    public init(text: String) {
        var rules: [Rule] = []
        var delay: TimeInterval?
        var applies = false
        var inGroup = false
        var sawUserAgentLine = false

        let ourNames = ["sourcedesk"]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "#").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                if sawUserAgentLine && !inGroup { inGroup = false }
                let agent = value.lowercased()
                applies = agent == "*" || ourNames.contains(where: { agent.contains($0) })
                sawUserAgentLine = true
                inGroup = true
            case "disallow":
                guard applies else { continue }
                if let parsed = Self.normalize(value) { rules.append(Rule(path: parsed, allow: false)) }
            case "allow":
                guard applies else { continue }
                if let parsed = Self.normalize(value) { rules.append(Rule(path: parsed, allow: true)) }
            case "crawl-delay":
                guard applies else { continue }
                if let parsed = TimeInterval(value) { delay = parsed }
            default:
                continue
            }
        }
        self.rules = rules
        self.crawlDelay = delay
    }

    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // "Disallow:" with an empty value means "allow everything".
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func evaluate(path rawPath: String, userAgent: String) -> WebDownloader.RobotsPolicy {
        guard !rules.isEmpty else { return .allowed }
        let path = rawPath.isEmpty ? "/" : rawPath
        var best: Rule?
        for rule in rules {
            guard Self.matches(pattern: rule.path, path: path) else { continue }
            if let current = best {
                if rule.specificity > current.specificity { best = rule }
                // On a tie, Allow wins (the specification's rule for equal length).
                else if rule.specificity == current.specificity && rule.allow { best = rule }
            } else {
                best = rule
            }
        }
        guard let winner = best else { return .allowed }
        return winner.allow ? .allowed : .disallowed(rule: winner.path)
    }

    static func matches(pattern: String, path: String) -> Bool {
        var pattern = pattern
        let anchoredEnd = pattern.hasSuffix("$")
        if anchoredEnd { pattern.removeLast() }
        let regexPattern = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            + (anchoredEnd ? "$" : "")
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }
}

/// robots.txt cache shared by downloads within one process.
final class RobotsCache: @unchecked Sendable {
    private var storage: [String: RobotsRules] = [:]
    private let lock = NSLock()

    func value(for key: String) -> RobotsRules? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func store(_ rules: RobotsRules, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = rules
    }
}
