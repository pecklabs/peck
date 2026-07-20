import Foundation

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PrContent {
    var title: String
    var body: String
    var diff: String
    var files: [(filename: String, status: String, additions: Int, deletions: Int)]
}

/// Talks to the GitHub REST + GraphQL APIs using the token in the keychain.
final class GitHubClient {
    static let shared = GitHubClient()

    enum Auth { case keychain, gh }

    private let session = URLSession(configuration: .ephemeral)
    private let iso = ISO8601DateFormatter()
    private var cachedViewer: GithubUser?
    var auth: Auth = .keychain
    private var ghTokenCache: String?

    private func token() throws -> String {
        switch auth {
        case .keychain:
            guard let t = Keychain.get(.githubToken) else {
                throw GitHubError(message: "GitHub token not set")
            }
            return t
        case .gh:
            if let t = ghTokenCache { return t }
            guard let path = Shell.resolve("gh"),
                  let r = try? Shell.runSync(path, ["auth", "token"]), r.exit == 0 else {
                throw GitHubError(message: "GitHub CLI token unavailable. Run `gh auth login`.")
            }
            let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw GitHubError(message: "GitHub CLI not logged in") }
            ghTokenCache = t
            return t
        }
    }

    /// Switch to using the `gh` CLI's existing login and return the user.
    func useGitHubCLI() async throws -> GithubUser {
        guard let path = Shell.resolve("gh") else {
            throw GitHubError(message: "GitHub CLI (gh) not found. Install it, then run `gh auth login`.")
        }
        let r = try await Shell.run(path, ["auth", "token"])
        let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.exit == 0, !t.isEmpty else {
            throw GitHubError(message: "Not logged in to gh. Run `gh auth login` in a terminal, then retry.")
        }
        ghTokenCache = t
        auth = .gh
        cachedViewer = nil
        return try await validateToken(t)
    }

    func useKeychain() {
        auth = .keychain
        ghTokenCache = nil
        cachedViewer = nil
    }

    private func date(_ s: Any?) -> Date {
        guard let str = s as? String else { return Date() }
        return iso.date(from: str) ?? Date()
    }

    // MARK: REST

    private func restRequest(_ path: String, accept: String = "application/vnd.github+json") throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.setValue("token \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("PRAgent", forHTTPHeaderField: "User-Agent")
        return req
    }

    func validateToken(_ token: String) async throws -> GithubUser {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PRAgent", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GitHubError(message: "Invalid GitHub token")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(message: "Unexpected response")
        }
        return GithubUser(
            login: obj["login"] as? String ?? "",
            name: obj["name"] as? String,
            avatarUrl: obj["avatar_url"] as? String ?? ""
        )
    }

    // MARK: GraphQL

    private func graphql(_ query: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("token \(try token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("PRAgent", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubError(message: "No response from GitHub")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError(message: "Malformed GitHub response")
        }
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw GitHubError(message: (first["message"] as? String) ?? "GraphQL error")
        }
        guard http.statusCode == 200, let dataField = json["data"] as? [String: Any] else {
            throw GitHubError(message: "GitHub returned status \(http.statusCode)")
        }
        return dataField
    }

    // MARK: Notifications (cheap conditional poll → near-real-time review-request push)

    private var notifLastModified: String?

    struct NotifSignal {
        /// Server-suggested seconds before the next poll (X-Poll-Interval).
        var pollAfterSec: Int
        /// A new "review requested" notification appeared since last poll.
        var newReviewRequest: Bool
    }

    /// Polls GitHub's Notifications API with `If-Modified-Since` — a 304 (nothing
    /// changed) is free and doesn't count against the rate limit. Returns whether
    /// a review was just requested so the app can fire a notification immediately.
    func pollReviewNotifications() async -> NotifSignal {
        guard let baseReq = try? restRequest("/notifications?participating=true") else {
            return NotifSignal(pollAfterSec: 60, newReviewRequest: false)
        }
        var req = baseReq
        if let lm = notifLastModified { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return NotifSignal(pollAfterSec: 60, newReviewRequest: false)
        }
        let pollAfter = Int(http.value(forHTTPHeaderField: "X-Poll-Interval") ?? "60") ?? 60
        if http.statusCode == 304 {
            return NotifSignal(pollAfterSec: pollAfter, newReviewRequest: false)
        }
        if let lm = http.value(forHTTPHeaderField: "Last-Modified") { notifLastModified = lm }
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let hasReviewRequest = arr.contains {
            ($0["reason"] as? String) == "review_requested" && (($0["unread"] as? Bool) ?? false)
        }
        return NotifSignal(pollAfterSec: pollAfter, newReviewRequest: hasReviewRequest)
    }

    func fetchViewer() async throws -> GithubUser {
        if let v = cachedViewer { return v }
        let data = try await graphql("query { viewer { login name avatarUrl } }")
        let viewer = data["viewer"] as? [String: Any] ?? [:]
        let user = GithubUser(
            login: viewer["login"] as? String ?? "",
            name: viewer["name"] as? String,
            avatarUrl: viewer["avatarUrl"] as? String ?? ""
        )
        cachedViewer = user
        return user
    }

    func resetViewerCache() { cachedViewer = nil }

    private func author(from node: [String: Any]) -> GithubUser {
        let a = node["author"] as? [String: Any]
        return GithubUser(
            login: a?["login"] as? String ?? "ghost",
            name: a?["name"] as? String,
            avatarUrl: a?["avatarUrl"] as? String ?? ""
        )
    }

    private let prFields = """
      number title url isDraft additions deletions changedFiles createdAt updatedAt
      author { login ... on User { name avatarUrl } }
      repository { name owner { login } }
    """

    func fetchReviewRequests() async throws -> [ReviewRequest] {
        let query = """
        query {
          search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 50) {
            nodes { ... on PullRequest {
              \(prFields)
              reviews(last: 50) { nodes { author { login } state commit { oid } } }
              commits(last: 1) { nodes { commit { oid } } }
            } }
          }
        }
        """
        let data = try await graphql(query)
        let viewer = try await fetchViewer()
        let nodes = ((data["search"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int else { return nil }
            let repo = node["repository"] as? [String: Any] ?? [:]
            let owner = (repo["owner"] as? [String: Any])?["login"] as? String ?? ""
            let repoName = repo["name"] as? String ?? ""
            let headOid = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first?["commit"] as? [String: Any])?["oid"] as? String
            let reviewNodes = ((node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let reviewed = reviewNodes.contains { r in
                let login = (r["author"] as? [String: Any])?["login"] as? String
                let state = r["state"] as? String
                let oid = (r["commit"] as? [String: Any])?["oid"] as? String
                return login == viewer.login && state != "PENDING" && (headOid == nil || oid == headOid)
            }
            return ReviewRequest(
                id: "\(owner)/\(repoName)#\(number)",
                owner: owner, repo: repoName, number: number,
                title: node["title"] as? String ?? "",
                url: node["url"] as? String ?? "",
                author: author(from: node),
                isDraft: node["isDraft"] as? Bool ?? false,
                additions: node["additions"] as? Int ?? 0,
                deletions: node["deletions"] as? Int ?? 0,
                changedFiles: node["changedFiles"] as? Int ?? 0,
                createdAt: date(node["createdAt"]),
                updatedAt: date(node["updatedAt"]),
                reviewed: reviewed
            )
        }
    }

    func fetchMyPullRequests() async throws -> [MyPullRequest] {
        let query = """
        query {
          search(query: "is:open is:pr author:@me archived:false", type: ISSUE, first: 50) {
            nodes { ... on PullRequest {
              \(prFields)
              reviewDecision mergeable
              reviewRequests(first: 50) { nodes { requestedReviewer { ... on User { login avatarUrl } } } }
              latestReviews(first: 50) { nodes { state author { login avatarUrl __typename } } }
              baseRef { branchProtectionRule { requiredApprovingReviewCount } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            } }
          }
        }
        """
        let data = try await graphql(query)
        let nodes = ((data["search"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int else { return nil }
            let repo = node["repository"] as? [String: Any] ?? [:]
            let owner = (repo["owner"] as? [String: Any])?["login"] as? String ?? ""
            let repoName = repo["name"] as? String ?? ""
            let allReviews = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            // Exclude bots (e.g. wiz-…[bot]) — they're not requested human reviewers.
            func isBotReview(_ r: [String: Any]) -> Bool {
                let author = r["author"] as? [String: Any]
                return (author?["__typename"] as? String) == "Bot"
                    || (author?["login"] as? String)?.hasSuffix("[bot]") == true
            }
            let reviews = allReviews.filter { !isBotReview($0) }
            let approvedCount = reviews.filter { ($0["state"] as? String) == "APPROVED" }.count
            let changesRequestedCount = reviews.filter { ($0["state"] as? String) == "CHANGES_REQUESTED" }.count
            let commentedCount = reviews.filter { ($0["state"] as? String) == "COMMENTED" }.count
            let reviewedCount = reviews.count
            let botReviewCount = allReviews.count - reviews.count
            let pendingNodes = (((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
                .compactMap { $0["requestedReviewer"] as? [String: Any] }
            let pendingReviewers: [String] = pendingNodes.compactMap { $0["login"] as? String }

            func reviewerState(_ s: String?) -> ReviewerStatus.State? {
                switch s {
                case "APPROVED": return .approved
                case "CHANGES_REQUESTED": return .changesRequested
                case "COMMENTED": return .commented
                default: return nil // DISMISSED/PENDING carry no current verdict
                }
            }
            func status(_ r: [String: Any], isBot: Bool) -> ReviewerStatus? {
                guard let author = r["author"] as? [String: Any],
                      let login = author["login"] as? String,
                      let state = reviewerState(r["state"] as? String) else { return nil }
                return ReviewerStatus(login: login, state: state, isBot: isBot,
                                      avatarUrl: author["avatarUrl"] as? String ?? "")
            }
            let reviewers: [ReviewerStatus] =
                reviews.compactMap { status($0, isBot: false) }
                + pendingNodes.compactMap { n -> ReviewerStatus? in
                    guard let login = n["login"] as? String else { return nil }
                    return ReviewerStatus(login: login, state: .pending,
                                          avatarUrl: n["avatarUrl"] as? String ?? "")
                }
                + allReviews.filter(isBotReview).compactMap { status($0, isBot: true) }
            let rollup = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
            let checks = Self.mapChecks(rollup?["state"] as? String)
            let required = ((node["baseRef"] as? [String: Any])?["branchProtectionRule"] as? [String: Any])?["requiredApprovingReviewCount"] as? Int

            return MyPullRequest(
                id: "\(owner)/\(repoName)#\(number)",
                owner: owner, repo: repoName, number: number,
                title: node["title"] as? String ?? "",
                url: node["url"] as? String ?? "",
                isDraft: node["isDraft"] as? Bool ?? false,
                reviewDecision: (node["reviewDecision"] as? String).flatMap(ReviewDecision.init),
                mergeable: Mergeable(rawValue: node["mergeable"] as? String ?? "UNKNOWN") ?? .unknown,
                checks: checks,
                approvedCount: approvedCount,
                changesRequestedCount: changesRequestedCount,
                pendingReviewers: pendingReviewers,
                updatedAt: date(node["updatedAt"]),
                requiredApprovals: max(1, required ?? 1),
                commentedCount: commentedCount,
                reviewedCount: reviewedCount,
                botReviewCount: botReviewCount,
                reviewers: reviewers
            )
        }
    }

    private static func mapChecks(_ v: String?) -> ChecksState {
        switch v {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING", "EXPECTED": return .pending
        default: return .none
        }
    }

    // MARK: PR content + submit

    func fetchPrContent(owner: String, repo: String, number: Int) async throws -> PrContent {
        async let metaData = fetchPrMeta(owner: owner, repo: repo, number: number)
        async let diffData = fetchPrDiff(owner: owner, repo: repo, number: number)
        async let filesData = fetchPrFiles(owner: owner, repo: repo, number: number)
        let (meta, diff, files) = try await (metaData, diffData, filesData)
        return PrContent(title: meta.0, body: meta.1, diff: diff, files: files)
    }

    private func fetchPrMeta(owner: String, repo: String, number: Int) async throws -> (String, String) {
        let req = try restRequest("/repos/\(owner)/\(repo)/pulls/\(number)")
        let (data, _) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (obj["title"] as? String ?? "", obj["body"] as? String ?? "")
    }

    private func fetchPrDiff(owner: String, repo: String, number: Int) async throws -> String {
        let req = try restRequest("/repos/\(owner)/\(repo)/pulls/\(number)", accept: "application/vnd.github.v3.diff")
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fetchPrFiles(owner: String, repo: String, number: Int) async throws
        -> [(filename: String, status: String, additions: Int, deletions: Int)] {
        let req = try restRequest("/repos/\(owner)/\(repo)/pulls/\(number)/files?per_page=100")
        let (data, _) = try await session.data(for: req)
        let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return arr.map {
            (filename: $0["filename"] as? String ?? "",
             status: $0["status"] as? String ?? "",
             additions: $0["additions"] as? Int ?? 0,
             deletions: $0["deletions"] as? Int ?? 0)
        }
    }

    /// All human-readable conversation on a PR: issue comments, inline review
    /// comments, and review summaries with a body — oldest first.
    func fetchPrComments(owner: String, repo: String, number: Int) async throws -> [PrComment] {
        async let issueData = restJSONArray("/repos/\(owner)/\(repo)/issues/\(number)/comments?per_page=100")
        async let inlineData = restJSONArray("/repos/\(owner)/\(repo)/pulls/\(number)/comments?per_page=100")
        async let reviewData = restJSONArray("/repos/\(owner)/\(repo)/pulls/\(number)/reviews?per_page=100")
        let (issue, inline, reviews) = try await (issueData, inlineData, reviewData)

        func author(_ o: [String: Any]) -> (String, String) {
            let u = o["user"] as? [String: Any]
            return (u?["login"] as? String ?? "ghost", u?["avatar_url"] as? String ?? "")
        }

        var out: [PrComment] = []
        for o in issue {
            let (login, avatar) = author(o)
            out.append(PrComment(id: "issue-\(o["id"] ?? UUID().uuidString)",
                                 author: login, avatarUrl: avatar,
                                 body: o["body"] as? String ?? "",
                                 createdAt: date(o["created_at"])))
        }
        for o in inline {
            let (login, avatar) = author(o)
            out.append(PrComment(id: "inline-\(o["id"] ?? UUID().uuidString)",
                                 author: login, avatarUrl: avatar,
                                 body: o["body"] as? String ?? "",
                                 createdAt: date(o["created_at"]),
                                 path: o["path"] as? String))
        }
        for o in reviews {
            let body = (o["body"] as? String) ?? ""
            let state = o["state"] as? String
            // Empty review bodies are noise here — verdicts already show in the
            // reviewer list; pending reviews aren't public yet.
            guard !body.isEmpty, state != "PENDING" else { continue }
            let (login, avatar) = author(o)
            out.append(PrComment(id: "review-\(o["id"] ?? UUID().uuidString)",
                                 author: login, avatarUrl: avatar,
                                 body: body,
                                 createdAt: date(o["submitted_at"]),
                                 verdict: state))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    private func restJSONArray(_ path: String) async throws -> [[String: Any]] {
        let req = try restRequest(path)
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    func submitReview(owner: String, repo: String, number: Int, verdict: Verdict,
                      body: String, comments: [InlineComment]) async throws {
        var req = try restRequest("/repos/\(owner)/\(repo)/pulls/\(number)/reviews")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["event": verdict.rawValue, "body": body]
        if !comments.isEmpty {
            payload["comments"] = comments.map { ["path": $0.path, "line": $0.line, "body": $0.body] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw GitHubError(message: msg ?? "Failed to submit review")
        }
    }
}
