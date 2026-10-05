import Foundation
import MCP

// MARK: - JSON Schema Helpers

/// Builds a JSON Schema "object" as a `Value` for MCP tool inputSchema.
private func objectSchema(
    properties: [String: Value],
    required: [String] = []
) -> Value {
    var schema: [String: Value] = [
        "type": .string("object"),
        "properties": .object(properties)
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map { .string($0) })
    }
    return .object(schema)
}

private func stringProp(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
}

private func intProp(_ description: String) -> Value {
    .object(["type": .string("integer"), "description": .string(description)])
}

private func stringArrayProp(_ description: String) -> Value {
    .object([
        "type": .string("array"),
        "description": .string(description),
        "items": .object(["type": .string("string")])
    ])
}

// MARK: - Tool Registration

/// Registers all MCP tool handlers.
func registerToolHandlers(on server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: allTools)
    }

    await server.withMethodHandler(CallTool.self) { (params: CallTool.Parameters) in
        try await handleToolCall(params)
    }
}

// MARK: - Tool Definitions

private let allTools: [Tool] = [
    Tool(
        name: "version",
        description: "Get the current version of the App Store MCP server.",
        inputSchema: objectSchema(properties: [:])
    ),
    Tool(
        name: "search_apps",
        description: """
            iTunes Search API. Supports attribute/genre filtering but rankings do NOT match \
            the App Store app. Use search_ranked when ranking position matters.
            """,
        inputSchema: objectSchema(
            properties: [
                "query": stringProp("Search term"),
                "limit": intProp("Max results (1-200, default 10)"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "attribute": stringProp("Search attribute filter. Valid: softwareDeveloper (exact match on developer name), descriptionTerm, keywordsTerm, genreIndex, ratingIndex"),
                "genre_id": intProp("Genre ID filter (e.g. 6014 for Games)"),
                "verbosity": stringProp("compact (default): id, name, developer, rating, reviews, price, bundleId, version, genre, minOS, released, updated, url. full: adds description + releaseNotes. complete: raw API response (~4KB/app, use limit≤10)")
            ],
            required: ["query"]
        )
    ),
    Tool(
        name: "search_ranked",
        description: """
            MZStore API — accurate App Store rankings. Position in results = actual App Store rank. \
            Use this instead of search_apps when ranking order matters.
            """,
        inputSchema: objectSchema(
            properties: [
                "query": stringProp("Search term"),
                "limit": intProp("Max results (default 20)"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "verbosity": stringProp("compact (default): id, name, developer, rating, reviews, price, bundleId, version, genre, minOS, released, updated, url. full: adds description + releaseNotes. complete: raw API response (~4KB/app, use limit≤10)")
            ],
            required: ["query"]
        )
    ),
    Tool(
        name: "lookup_app",
        description: """
            Direct lookup by app ID, bundle ID, or App Store URL. Returns full details including \
            description. Provide exactly one identifier parameter.
            """,
        inputSchema: objectSchema(
            properties: [
                "app_id": stringProp("Single app ID (numeric)"),
                "app_ids": stringProp("Comma-separated app IDs"),
                "bundle_id": stringProp("Bundle identifier (e.g. com.example.app)"),
                "url": stringProp("App Store URL"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "verbosity": stringProp("compact: id, name, developer, rating, reviews, price, bundleId, version, genre, minOS, released, updated, url. full (default): adds description + releaseNotes. complete: raw API response (~4KB/app)")
            ]
        )
    ),
    Tool(
        name: "top_charts",
        description: "Current App Store top chart rankings via RSS feed.",
        inputSchema: objectSchema(
            properties: [
                "chart_type": stringProp("Chart type: free, paid, grossing, newfree, newpaid"),
                "limit": intProp("Number of entries (default 25)"),
                "genre_id": intProp("Genre ID filter"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "verbosity": stringProp("compact (default): name, id, developer, price, category, url. full: adds RSS summary/description")
            ],
            required: ["chart_type"]
        )
    ),
    Tool(
        name: "find_app_rank",
        description: "Check where a specific app ranks for a single keyword. Returns rank + top 5 competitors.",
        inputSchema: objectSchema(
            properties: [
                "app_id": stringProp("App ID to find (numeric)"),
                "keyword": stringProp("Search keyword"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "verbosity": stringProp("compact (default): id, name, developer, rating, reviews, price, genre, url. full: adds description + releaseNotes. complete: raw API response")
            ],
            required: ["app_id", "keyword"]
        )
    ),
    Tool(
        name: "check_app_rankings",
        description: """
            Check how an app ranks across auto-generated keywords. SLOW (30-120s) due to \
            rate-limited sequential API calls. Use find_app_rank for single keyword checks.
            """,
        inputSchema: objectSchema(
            properties: [
                "app_id": stringProp("App ID (numeric)"),
                "keyword_limit": intProp("Max keywords to test (default 15)"),
                "storefront": stringProp("Two-letter country code (default: US)")
            ],
            required: ["app_id"]
        )
    ),
    Tool(
        name: "analyze_keyword",
        description: """
            Competitive analysis of top 20 results for a search term. Returns per-app metrics, \
            competitiveness score (0-100), and trend signal. Saves results to analytics database.
            """,
        inputSchema: objectSchema(
            properties: [
                "keyword": stringProp("Search term to analyze"),
                "storefront": stringProp("Two-letter country code (default: US)")
            ],
            required: ["keyword"]
        )
    ),
    Tool(
        name: "app_competitors",
        description: """
            Find an app's top competitors by analyzing overlapping ranked search results. \
            Searches for the app name and key terms, identifies apps appearing across multiple searches.
            """,
        inputSchema: objectSchema(
            properties: [
                "app_id": stringProp("App ID (numeric)"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "verbosity": stringProp("compact (default): id, name, developer, rating, reviews, price, genre, url. full: adds description + releaseNotes. complete: raw API response")
            ],
            required: ["app_id"]
        )
    ),
    Tool(
        name: "compare_keywords",
        description: """
            Compare competitiveness across multiple keywords. Finds the least competitive niches. \
            SLOW (~5-10s per keyword due to rate limiting). Max 10 keywords.
            """,
        inputSchema: objectSchema(
            properties: [
                "keywords": stringArrayProp("List of keywords to compare (max 10)"),
                "storefront": stringProp("Two-letter country code (default: US)")
            ],
            required: ["keywords"]
        )
    ),
    Tool(
        name: "discover_trending",
        description: """
            Discover trending app categories by analyzing new chart entries. \
            Groups new apps by genre with velocity metrics and trend assessment.
            """,
        inputSchema: objectSchema(
            properties: [
                "genre_id": intProp("Genre ID to filter (optional, omit for all genres)"),
                "storefront": stringProp("Two-letter country code (default: US)"),
                "limit": intProp("Max new apps to analyze (default 15)")
            ]
        )
    )
]

private let maxMCPLimit = 1000

// MARK: - Tool Dispatch

private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
    let args = params.arguments ?? [:]

    switch params.name {
    case "version":
        return CallTool.Result(content: [.text(text: appVersion, annotations: nil, _meta: nil)])
    case "search_apps":
        return try await handleSearchApps(args)
    case "search_ranked":
        return try await handleSearchRanked(args)
    case "lookup_app":
        return try await handleLookupApp(args)
    case "top_charts":
        return try await handleTopCharts(args)
    case "find_app_rank":
        return try await handleFindAppRank(args)
    case "check_app_rankings":
        return try await handleCheckAppRankings(args)
    case "analyze_keyword":
        return try await handleAnalyzeKeyword(args)
    case "app_competitors":
        return try await handleAppCompetitors(args)
    case "compare_keywords":
        return try await handleCompareKeywords(args)
    case "discover_trending":
        return try await handleDiscoverTrending(args)
    default:
        throw MCPError.invalidRequest("Unknown tool: \(params.name)")
    }
}

// MARK: - Helper: JSON encoding to tool result

private func jsonResult(_ value: Any) throws -> CallTool.Result {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
}

private func encodableResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
}

private func errorResult(_ message: String) -> CallTool.Result {
    let errorDict = ["error": message]
    do {
        let data = try JSONSerialization.data(withJSONObject: errorDict)
        let json = String(data: data, encoding: .utf8) ?? "{\"error\":\"Encoding error\"}"
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: true)
    } catch {
        // Serializing a [String: String] dict cannot fail, but handle it anyway
        return CallTool.Result(content: [.text(text: "{\"error\":\"Internal serialization error\"}", annotations: nil, _meta: nil)], isError: true)
    }
}

// MARK: - Helper: encode apps with verbosity

private func encodeApps(_ apps: [App], verbosity: String) throws -> CallTool.Result {
    switch verbosity {
    case "complete":
        return try encodableResult(apps)
    case "full":
        return try encodableResult(apps.map { FullApp(from: $0) })
    default:
        return try encodableResult(apps.map { CompactApp(from: $0) })
    }
}

private func encodeAppsToJSONObject(_ apps: [App], verbosity: String) throws -> Any {
    let data: Data
    switch verbosity {
    case "complete":
        data = try JSONEncoder().encode(apps)
    case "full":
        data = try JSONEncoder().encode(apps.map { FullApp(from: $0) })
    default:
        data = try JSONEncoder().encode(apps.map { CompactApp(from: $0) })
    }
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: - Helper: extract args

private func stringArg(_ args: [String: Value], _ key: String) -> String? {
    guard let val = args[key] else { return nil }
    switch val {
    case .string(let s): return s
    case .int(let i): return String(i)
    case .double(let f): return String(Int(f))
    default: return nil
    }
}

private func intArg(_ args: [String: Value], _ key: String) -> Int? {
    guard let val = args[key] else { return nil }
    switch val {
    case .int(let i): return i
    case .double(let f): return Int(f)
    case .string(let s): return Int(s)
    default: return nil
    }
}

private func stringArrayArg(_ args: [String: Value], _ key: String) -> [String]? {
    guard let val = args[key] else { return nil }
    switch val {
    case .array(let arr):
        return arr.compactMap { element in
            switch element {
            case .string(let s): return s
            default: return nil
            }
        }
    default: return nil
    }
}

// MARK: - Tool Implementations

private func handleSearchApps(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let query = stringArg(args, "query") else {
        return errorResult("Missing required parameter: query")
    }
    let limit = min(intArg(args, "limit") ?? 10, maxMCPLimit)
    let storefront = stringArg(args, "storefront") ?? "US"
    let attribute = stringArg(args, "attribute")
    let genreId = intArg(args, "genre_id")
    let verbosity = stringArg(args, "verbosity") ?? "compact"

    if let attribute, !SearchAttribute.validForSoftware.contains(attribute) {
        let validList = SearchAttribute.validForSoftware.sorted().joined(separator: ", ")
        return errorResult("Invalid attribute: \(attribute). Valid attributes for software searches: \(validList)")
    }

    let api = AppStoreAPI()
    // When searching by developer, request extra results since we'll post-filter
    let fetchLimit = attribute == "softwareDeveloper" ? 200 : limit
    let result = try await api.searchWithRawData(
        query: query,
        limit: fetchLimit,
        storefront: storefront,
        attribute: attribute,
        genre: genreId
    )

    var apps = result.apps

    // Apple's API does keyword matching ("Nuclear" OR "Cyborg" OR "Corp"), not phrase matching.
    // Post-filter to only apps whose developer name actually contains the full query.
    if attribute == "softwareDeveloper" {
        let queryLower = query.lowercased()
        apps = apps.filter { $0.artistName.lowercased().contains(queryLower) }
    }

    let limitedApps = Array(apps.prefix(limit))
    return try encodeApps(limitedApps, verbosity: verbosity)
}

private func handleSearchRanked(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let query = stringArg(args, "query") else {
        return errorResult("Missing required parameter: query")
    }
    let limit = min(intArg(args, "limit") ?? 20, maxMCPLimit)
    let storefront = stringArg(args, "storefront") ?? "US"
    let verbosity = stringArg(args, "verbosity") ?? "compact"

    let rankedAppIds = try await ScrapeCommand.fetchRankedAppIds(
        term: query,
        storefront: storefront,
        language: "en-us",
        limit: limit
    )

    guard !rankedAppIds.isEmpty else {
        return try encodableResult([CompactApp]())
    }

    let limitedIds = Array(rankedAppIds.prefix(limit))
    let apps = try await AppStoreAPI.lookupAppDetails(
        appIds: limitedIds,
        storefront: storefront,
        language: "en-us"
    )

    // Preserve ranked order from MZStore
    let idToApp = Dictionary(uniqueKeysWithValues: apps.map { (String($0.trackId), $0) })
    let orderedApps = limitedIds.compactMap { idToApp[$0] }
    return try encodeApps(orderedApps, verbosity: verbosity)
}

private func handleLookupApp(_ args: [String: Value]) async throws -> CallTool.Result {
    let storefront = stringArg(args, "storefront") ?? "US"
    let verbosity = stringArg(args, "verbosity") ?? "full"
    let api = AppStoreAPI()

    let lookupType: LookupType
    if let appId = stringArg(args, "app_id") {
        lookupType = .id(appId)
    } else if let appIds = stringArg(args, "app_ids") {
        lookupType = .ids(appIds.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
    } else if let bundleId = stringArg(args, "bundle_id") {
        lookupType = .bundleId(bundleId)
    } else if let url = stringArg(args, "url") {
        lookupType = .url(url)
    } else {
        return errorResult("Provide exactly one of: app_id, app_ids, bundle_id, or url")
    }

    let result = try await api.lookupWithRawData(
        lookupType: lookupType,
        storefront: storefront
    )

    return try encodeApps(result.apps, verbosity: verbosity)
}

private func handleTopCharts(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let chartTypeStr = stringArg(args, "chart_type") else {
        return errorResult("Missing required parameter: chart_type")
    }

    let chartType: TopChartType
    switch chartTypeStr.lowercased() {
    case "free": chartType = .free
    case "paid": chartType = .paid
    case "grossing": chartType = .grossing
    case "newfree", "new_free": chartType = .newFree
    case "newpaid", "new_paid": chartType = .newPaid
    default:
        return errorResult("Invalid chart_type: \(chartTypeStr). Valid: free, paid, grossing, newfree, newpaid")
    }

    let limit = min(intArg(args, "limit") ?? 25, maxMCPLimit)
    let storefront = stringArg(args, "storefront") ?? "US"
    let genreId = intArg(args, "genre_id")
    let verbosity = stringArg(args, "verbosity") ?? "compact"

    let entries = try await TopCommand.fetchTopChartEntries(
        chartType: chartType,
        storefront: storefront,
        limit: limit,
        genre: genreId
    )

    switch verbosity {
    case "full", "complete":
        return try encodableResult(entries)
    default:
        return try encodableResult(entries.map { CompactTopChartEntry(from: $0) })
    }
}

private func handleFindAppRank(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let appId = stringArg(args, "app_id") else {
        return errorResult("Missing required parameter: app_id")
    }
    guard let keyword = stringArg(args, "keyword") else {
        return errorResult("Missing required parameter: keyword")
    }
    let storefront = stringArg(args, "storefront") ?? "US"
    let verbosity = stringArg(args, "verbosity") ?? "compact"

    let rankedAppIds = try await ScrapeCommand.fetchRankedAppIds(
        term: keyword,
        storefront: storefront,
        language: "en-us",
        limit: 200
    )

    var rank: Int? = nil
    for (idx, id) in rankedAppIds.enumerated() where id == appId {
        rank = idx + 1
        break
    }

    // Get top 5 for competitors
    let top5Ids = Array(rankedAppIds.prefix(5))
    var topCompetitorApps: [App] = []
    if !top5Ids.isEmpty {
        let apps = try await AppStoreAPI.lookupAppDetails(
            appIds: top5Ids,
            storefront: storefront,
            language: "en-us"
        )
        let idToApp = Dictionary(uniqueKeysWithValues: apps.map { (String($0.trackId), $0) })
        topCompetitorApps = top5Ids.compactMap { idToApp[$0] }
    }

    var result: [String: Any] = [
        "keyword": keyword,
        "total_results": rankedAppIds.count
    ]
    if let rank = rank {
        result["rank"] = rank
    }

    // Encode top competitors with requested verbosity
    result["top_competitors"] = try encodeAppsToJSONObject(topCompetitorApps, verbosity: verbosity)

    return try jsonResult(result)
}

private func handleCheckAppRankings(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let appId = stringArg(args, "app_id") else {
        return errorResult("Missing required parameter: app_id")
    }
    let keywordLimit = min(intArg(args, "keyword_limit") ?? 15, maxMCPLimit)
    let storefront = stringArg(args, "storefront") ?? "US"

    // Look up the app first
    let appDetails = try await AppStoreAPI.lookupAppDetails(
        appIds: [appId],
        storefront: storefront,
        language: "en-us"
    )

    guard let app = appDetails.first else {
        return errorResult("No app found with ID \(appId)")
    }

    // Generate keywords from app title, genre, and developer
    let titleLower = app.trackName.lowercased()
    let titleWords = titleLower.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

    var searchTerms: Set<String> = []
    searchTerms.insert(titleLower)
    for word in titleWords {
        searchTerms.insert(word)
        // Add punctuation-stripped variants
        if word.rangeOfCharacter(from: .punctuationCharacters) != nil {
            let stripped = word.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
            let strippedStr = String(String.UnicodeScalarView(stripped))
            if !strippedStr.isEmpty {
                searchTerms.insert(strippedStr)
            }
        }
    }

    // Add 2-word combos from title
    if titleWords.count > 1 {
        for i in 0..<titleWords.count {
            for j in 0..<titleWords.count where i != j {
                searchTerms.insert("\(titleWords[i]) \(titleWords[j])")
            }
        }
    }

    // Genre words (e.g., "Social Networking" → "social", "networking", "social networking")
    let genreLower = app.primaryGenreName.lowercased()
    let genreWords = genreLower.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    for word in genreWords {
        searchTerms.insert(word)
    }
    if genreWords.count > 1 {
        searchTerms.insert(genreLower)
    }

    // Title × genre cross-terms
    for titleWord in titleWords {
        for genreWord in genreWords {
            searchTerms.insert("\(titleWord) \(genreWord)")
        }
    }

    // Developer name words (excluding corporate suffixes)
    let corporateSuffixes: Set<String> = ["inc", "inc.", "llc", "ltd", "ltd.", "corp", "corp.", "co", "co."]
    let developerWords = app.artistName.lowercased()
        .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        .filter { !$0.isEmpty && $0.count > 2 && !corporateSuffixes.contains($0) }
    for word in developerWords {
        searchTerms.insert(word)
    }

    let keywords = Array(searchTerms.prefix(keywordLimit))

    // Check ranking for each keyword
    var rankings: [[String: Any]] = []
    for keyword in keywords {
        do {
            let rankedAppIds = try await ScrapeCommand.fetchRankedAppIds(
                term: keyword,
                storefront: storefront,
                language: "en-us",
                limit: 200
            )

            var rank: Int? = nil
            for (idx, id) in rankedAppIds.enumerated() where id == appId {
                rank = idx + 1
                break
            }

            var entry: [String: Any] = [
                "keyword": keyword,
                "totalResults": rankedAppIds.count
            ]
            if let rank = rank {
                entry["rank"] = rank
            }
            rankings.append(entry)
        } catch {
            rankings.append([
                "keyword": keyword,
                "error": error.localizedDescription
            ])
        }
    }

    let appInfo: [String: Any] = [
        "id": app.trackId,
        "name": app.trackName,
        "developer": app.artistName
    ]

    let result: [String: Any] = [
        "app": appInfo,
        "keywordsTested": keywords.count,
        "rankings": rankings
    ]

    return try jsonResult(result)
}

private func handleAnalyzeKeyword(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let keyword = stringArg(args, "keyword") else {
        return errorResult("Missing required parameter: keyword")
    }
    let storefront = stringArg(args, "storefront") ?? "US"

    let (analyzedApps, summary, _) = try await AnalyzeCommand.runAnalysis(
        term: keyword,
        storefront: storefront,
        language: "en-us"
    )

    let trendSignal: String
    if summary.velocityRatio > 1.5 {
        trendSignal = "heating_up"
    } else if summary.velocityRatio < 0.5 {
        trendSignal = "established_dominated"
    } else {
        trendSignal = "stable"
    }

    var appEntries: [[String: Any]] = []
    for (index, analyzed) in analyzedApps.enumerated() {
        let app = analyzed.app
        appEntries.append([
            "rank": index + 1,
            "id": app.trackId,
            "name": app.trackName,
            "rating": app.averageUserRating ?? 0.0,
            "reviews": app.userRatingCount ?? 0,
            "ageDays": analyzed.ageDays,
            "ratingsPerDay": round(analyzed.ratingsPerDay * 100) / 100,
            "titleMatch": analyzed.titleMatchScore,
            "descMatch": analyzed.descriptionMatchScore
        ])
    }

    let result: [String: Any] = [
        "keyword": keyword,
        "competitiveness": round(summary.competitivenessV1 * 10) / 10,
        "trend_signal": trendSignal,
        "summary": [
            "avgRating": round(summary.avgRating * 10) / 10,
            "avgAgeDays": summary.avgAgeDays,
            "avgRatingsPerDay": round(summary.avgRatingsPerDay * 10) / 10,
            "newestVelocity": round(summary.newestVelocity * 10) / 10,
            "establishedVelocity": round(summary.establishedVelocity * 10) / 10,
            "velocityRatio": round(summary.velocityRatio * 100) / 100
        ] as [String: Any],
        "apps": appEntries
    ]

    return try jsonResult(result)
}

private func handleAppCompetitors(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let appId = stringArg(args, "app_id") else {
        return errorResult("Missing required parameter: app_id")
    }
    let storefront = stringArg(args, "storefront") ?? "US"
    let verbosity = stringArg(args, "verbosity") ?? "compact"

    // Look up the target app
    let appDetails = try await AppStoreAPI.lookupAppDetails(
        appIds: [appId],
        storefront: storefront,
        language: "en-us"
    )

    guard let app = appDetails.first else {
        return errorResult("No app found with ID \(appId)")
    }

    // Build search terms from app name (deduplicated, preserving insertion order)
    let fullName = app.trackName
    let nameWords = fullName.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty && $0.count > 2 }

    var seen: Set<String> = []
    var searchTerms: [String] = []
    let fullNameLower = fullName.lowercased()
    seen.insert(fullNameLower)
    searchTerms.append(fullNameLower)

    // Add up to 2 key terms (longest words from name, likely most descriptive)
    let sortedByLength = nameWords.sorted { $0.count > $1.count }
    for word in sortedByLength.prefix(2) where !seen.contains(word) {
        seen.insert(word)
        searchTerms.append(word)
    }

    // Collect app IDs across all searches with frequency
    var appFrequency: [String: Int] = [:]
    var ownRankForName: Int? = nil

    for (searchIndex, term) in searchTerms.enumerated() {
        do {
            let rankedIds = try await ScrapeCommand.fetchRankedAppIds(
                term: term,
                storefront: storefront,
                language: "en-us",
                limit: 30
            )

            // Track own rank for name search
            if searchIndex == 0 {
                for (idx, id) in rankedIds.enumerated() where id == appId {
                    ownRankForName = idx + 1
                    break
                }
            }

            for id in rankedIds where id != appId {
                appFrequency[id, default: 0] += 1
            }
        } catch {
            // Skip failed searches
        }
    }

    // Sort by frequency (most overlap = strongest competitor signal)
    let sortedCompetitors = appFrequency.sorted { $0.value > $1.value }
    let topCompetitorIds = sortedCompetitors.prefix(10).map { $0.key }

    var competitors: [[String: Any]] = []
    if !topCompetitorIds.isEmpty {
        let competitorApps = try await AppStoreAPI.lookupAppDetails(
            appIds: topCompetitorIds,
            storefront: storefront,
            language: "en-us"
        )

        let idToApp = Dictionary(uniqueKeysWithValues: competitorApps.map { (String($0.trackId), $0) })
        let encoder = JSONEncoder()
        for (id, freq) in sortedCompetitors.prefix(10) {
            if let competitorApp = idToApp[id] {
                let appData: Data
                switch verbosity {
                case "complete":
                    appData = try encoder.encode(competitorApp)
                case "full":
                    appData = try encoder.encode(FullApp(from: competitorApp))
                default:
                    appData = try encoder.encode(CompactApp(from: competitorApp))
                }
                var appDict = try JSONSerialization.jsonObject(with: appData) as? [String: Any] ?? [:]
                appDict["overlap_count"] = freq
                competitors.append(appDict)
            }
        }
    }

    var targetInfo: [String: Any] = [
        "id": app.trackId,
        "name": app.trackName,
        "developer": app.artistName
    ]
    if let rank = ownRankForName {
        targetInfo["rank_for_own_name"] = rank
    }

    let result: [String: Any] = [
        "target_app": targetInfo,
        "searches_performed": searchTerms,
        "competitors": competitors
    ]

    return try jsonResult(result)
}

private func handleCompareKeywords(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let keywords = stringArrayArg(args, "keywords") else {
        return errorResult("Missing required parameter: keywords (array of strings)")
    }

    guard keywords.count <= 10 else {
        return errorResult("Maximum 10 keywords allowed")
    }

    guard !keywords.isEmpty else {
        return errorResult("At least one keyword required")
    }

    let storefront = stringArg(args, "storefront") ?? "US"

    var comparisons: [[String: Any]] = []
    var lowestCompetitiveness: Double = 101
    var recommendedKeyword: String = keywords[0]

    for keyword in keywords {
        do {
            let (_, summary, _) = try await AnalyzeCommand.runAnalysis(
                term: keyword,
                storefront: storefront,
                language: "en-us"
            )

            let trendSignal: String
            if summary.velocityRatio > 1.5 {
                trendSignal = "heating_up"
            } else if summary.velocityRatio < 0.5 {
                trendSignal = "established_dominated"
            } else {
                trendSignal = "stable"
            }

            let comp = round(summary.competitivenessV1 * 10) / 10

            comparisons.append([
                "keyword": keyword,
                "competitiveness": comp,
                "trend": trendSignal,
                "avgRating": round(summary.avgRating * 10) / 10,
                "avgRatingsPerDay": round(summary.avgRatingsPerDay * 10) / 10,
                "topAppReviews": summary.avgRatingCount
            ])

            if comp < lowestCompetitiveness {
                lowestCompetitiveness = comp
                recommendedKeyword = keyword
            }
        } catch {
            comparisons.append([
                "keyword": keyword,
                "error": error.localizedDescription
            ])
        }
    }

    let result: [String: Any] = [
        "comparisons": comparisons,
        "recommendation": recommendedKeyword
    ]

    return try jsonResult(result)
}

private func handleDiscoverTrending(_ args: [String: Value]) async throws -> CallTool.Result {
    let storefront = stringArg(args, "storefront") ?? "US"
    let genreId = intArg(args, "genre_id")
    let limit = min(intArg(args, "limit") ?? 15, maxMCPLimit)

    // Fetch new free and new paid charts
    let newFreeEntries = try await TopCommand.fetchTopChartEntries(
        chartType: .newFree,
        storefront: storefront,
        limit: limit,
        genre: genreId
    )

    let newPaidEntries = try await TopCommand.fetchTopChartEntries(
        chartType: .newPaid,
        storefront: storefront,
        limit: limit,
        genre: genreId
    )

    let allNewEntries = newFreeEntries + newPaidEntries

    // Look up full details for these apps
    let appIds = allNewEntries.compactMap { entry -> String? in
        entry.id.isEmpty ? nil : entry.id
    }

    var appsById: [String: App] = [:]
    if !appIds.isEmpty {
        let uniqueIds = Array(Set(appIds))
        let apps = try await AppStoreAPI.lookupAppDetails(
            appIds: uniqueIds,
            storefront: storefront,
            language: "en-us"
        )
        for app in apps {
            appsById[String(app.trackId)] = app
        }
    }

    // Group by genre
    var genreGroups: [String: [(entry: TopChartEntry, app: App?)]] = [:]
    for entry in allNewEntries {
        let app = appsById[entry.id]
        let genre = app?.primaryGenreName ?? entry.category
        genreGroups[genre, default: []].append((entry: entry, app: app))
    }

    // Build output grouped by genre
    var genreResults: [[String: Any]] = []
    for (genre, items) in genreGroups.sorted(by: { $0.value.count > $1.value.count }) {
        var appList: [[String: Any]] = []
        var totalRatingsPerDay: Double = 0
        var appsWithVelocity = 0

        for item in items {
            var appEntry: [String: Any] = [
                "name": item.entry.name,
                "id": item.entry.id,
                "price": item.entry.price
            ]

            if let app = item.app {
                let releaseDate = AnalyzeCommand.parseDate(app.releaseDate ?? "")
                let ageDays = releaseDate.map { Int(Date().timeIntervalSince($0) / 86400) } ?? 0
                let reviews = app.userRatingCount ?? 0
                let velocity = ageDays > 0 ? Double(reviews) / Double(ageDays) : 0

                appEntry["rating"] = app.averageUserRating
                appEntry["reviews"] = reviews
                appEntry["ageDays"] = ageDays
                appEntry["ratingsPerDay"] = round(velocity * 100) / 100

                totalRatingsPerDay += velocity
                appsWithVelocity += 1
            }
            appList.append(appEntry)
        }

        let avgVelocity = appsWithVelocity > 0 ? totalRatingsPerDay / Double(appsWithVelocity) : 0

        let trendAssessment: String
        if avgVelocity > 5 {
            trendAssessment = "hot"
        } else if avgVelocity > 1 {
            trendAssessment = "growing"
        } else {
            trendAssessment = "emerging"
        }

        genreResults.append([
            "genre": genre,
            "app_count": items.count,
            "avg_velocity": round(avgVelocity * 100) / 100,
            "trend": trendAssessment,
            "apps": appList
        ])
    }

    let result: [String: Any] = [
        "storefront": storefront,
        "genres": genreResults
    ]

    return try jsonResult(result)
}
