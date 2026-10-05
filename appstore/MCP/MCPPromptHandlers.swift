import Foundation
import MCP

/// Registers MCP prompt handlers for guided workflows.
func registerPromptHandlers(on server: Server) async {
    await server.withMethodHandler(ListPrompts.self) { _ in
        ListPrompts.Result(prompts: [
            Prompt(
                name: "competitive_analysis",
                description: "Guides analysis of an app's competitive position: lookup, competitors, keyword rankings, and actionable recommendations.",
                arguments: [
                    Prompt.Argument(
                        name: "keyword_or_app_id",
                        description: "An app ID (numeric) or keyword to analyze",
                        required: true
                    ),
                    Prompt.Argument(
                        name: "storefront",
                        description: "Two-letter country code (default: US)",
                        required: false
                    )
                ]
            ),
            Prompt(
                name: "market_research",
                description: "Guides research of a market segment: search rankings, top charts, competitiveness analysis, trending discovery, and opportunity identification.",
                arguments: [
                    Prompt.Argument(
                        name: "category",
                        description: "Market category or keyword to research (e.g. 'photo editor', 'fitness tracker')",
                        required: true
                    ),
                    Prompt.Argument(
                        name: "storefront",
                        description: "Two-letter country code (default: US)",
                        required: false
                    )
                ]
            )
        ])
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        switch params.name {
        case "competitive_analysis":
            return competitiveAnalysisPrompt(params: params)
        case "market_research":
            return marketResearchPrompt(params: params)
        default:
            throw MCPError.invalidRequest("Unknown prompt: \(params.name)")
        }
    }
}

// MARK: - Prompt Builders

private func competitiveAnalysisPrompt(params: GetPrompt.Parameters) -> GetPrompt.Result {
    let target = params.arguments?["keyword_or_app_id"] ?? "the target app"
    let storefront = params.arguments?["storefront"] ?? "US"

    let message = """
    Perform a competitive analysis for "\(target)" on the \(storefront) App Store. Follow these steps:

    1. **Identify the app**: If "\(target)" is a numeric ID, use `lookup_app` to get its details. \
    If it's a keyword, use `search_ranked` to find the top result, then look it up.

    2. **Find competitors**: Use `app_competitors` with the app's ID to discover competing apps.

    3. **Analyze keyword competitiveness**: Use `analyze_keyword` on the app's name and 2-3 \
    relevant keywords from its genre/description.

    4. **Check rankings**: Use `find_app_rank` for the most relevant keywords to see where \
    this app ranks.

    5. **Summarize findings**:
       - App's current competitive position (strong/moderate/weak)
       - Key competitors and their advantages
       - Best and worst keyword rankings
       - Competitiveness scores for each keyword analyzed
       - Actionable recommendations for improving App Store visibility
    """

    return GetPrompt.Result(
        description: "Competitive analysis for \(target)",
        messages: [
            .user(.text(text: message))
        ]
    )
}

private func marketResearchPrompt(params: GetPrompt.Parameters) -> GetPrompt.Result {
    let category = params.arguments?["category"] ?? "the target category"
    let storefront = params.arguments?["storefront"] ?? "US"

    let message = """
    Research the "\(category)" market segment on the \(storefront) App Store. Follow these steps:

    1. **Search ranked results**: Use `search_ranked` for "\(category)" to see what users find \
    when they search for this.

    2. **Check top charts**: Use `top_charts` (free and paid) to see if any relevant apps are \
    trending. If a genre ID is known, filter by it.

    3. **Analyze competitiveness**: Use `analyze_keyword` on "\(category)" and 2-3 related \
    keywords or variations.

    4. **Discover trends**: Use `discover_trending` to see what's emerging in this space.

    5. **Compare keywords**: Use `compare_keywords` with 3-5 relevant keyword variations \
    (e.g., for "photo editor": ["photo editor", "image editor", "picture editor", "photo filter"]).

    6. **Summarize findings**:
       - Market saturation level (high/medium/low)
       - Dominant players and their market share signals (review counts, ratings velocity)
       - Trending signals and emerging opportunities
       - Underserved niches or keywords with lower competition
       - Recommended positioning strategy for a new entrant
       - Best keywords to target (lowest competitiveness with adequate search volume)
    """

    return GetPrompt.Result(
        description: "Market research for \(category)",
        messages: [
            .user(.text(text: message))
        ]
    )
}
