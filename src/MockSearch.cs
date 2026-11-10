using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace BingDomainGuard;

public sealed record MockResponse(HttpStatusCode Status, string Body, string ContentType = "application/json; charset=utf-8");

public static partial class MockSearch
{
    [GeneratedRegex(@"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$", RegexOptions.IgnoreCase)]
    private static partial Regex HostnamePattern();

    public static MockResponse Create(string query, string scenario, string domain = "panasonic.jp",
        string exceptionDomain = "exceptions.example")
    {
        if (!HostnamePattern().IsMatch(domain) || !HostnamePattern().IsMatch(exceptionDomain))
        {
            throw new ArgumentException("Mock domains must be DNS hostnames without schemes, paths or wildcards.");
        }

        var results = new JsonArray(
            Result($"https://{domain}/aircon/", 0),
            Result("https://www.technics.com/jp/", 1));
        var pages = new JsonObject
        {
            ["webSearchUrl"] = $"https://www.bing.com/search?q={Uri.EscapeDataString(query)}",
            ["totalEstimatedMatches"] = 2,
            ["value"] = results
        };
        var body = new JsonObject
        {
            ["_type"] = "SearchResponse",
            ["queryContext"] = new JsonObject { ["originalQuery"] = query },
            ["webPages"] = pages,
            ["rankingResponse"] = new JsonObject
            {
                ["mainline"] = new JsonObject
                {
                    ["items"] = new JsonArray(
                        RankingItem(0),
                        RankingItem(1))
                }
            }
        };

        switch (scenario)
        {
            case "good":
                break;
            case "subdomain":
                results[1]!["url"] = $"https://support.{domain}/faq/";
                break;
            case "mixed":
                results.Add(Result("https://outside.example/article", 2));
                pages["totalEstimatedMatches"] = 3;
                body["rankingResponse"]!["mainline"]!["items"]!.AsArray()
                    .Add(RankingItem(2));
                break;
            case "all-bad":
                results[0]!["url"] = "https://outside.example/a";
                results[1]!["url"] = "https://unrelated.example/b";
                break;
            case "exception":
                results[0]!["url"] = $"https://{exceptionDomain}/a";
                results[1]!["url"] = $"https://support.{exceptionDomain}/b";
                break;
            case "deep-link":
                results[0]!["deepLinks"] = new JsonArray(new JsonObject
                {
                    ["name"] = "External deep link", ["url"] = "https://outside.example/deep"
                });
                break;
            case "lookalike":
                results[1]!["url"] = "https://panasonic-campaign.example.com/";
                break;
            case "suffix-attack":
                results[1]!["url"] = $"https://{exceptionDomain}.outside.example/";
                break;
            case "prefix-attack":
                results[1]!["url"] = $"https://not-{exceptionDomain}/";
                break;
            case "userinfo-attack":
                results[1]!["url"] = $"https://{domain}@outside.example/";
                break;
            case "path-attack":
                results[1]!["url"] = "https://outside.example/panasonic/";
                break;
            case "invalid-url":
                results[1]!["url"] = "not-an-absolute-url";
                break;
            case "missing-url":
                results[1]!.AsObject().Remove("url");
                break;
            case "empty":
                body.Remove("webPages");
                body.Remove("rankingResponse");
                break;
            case "empty-array":
                results.Clear();
                pages["totalEstimatedMatches"] = 0;
                body.Remove("rankingResponse");
                break;
            case "invalid-json":
                return new(HttpStatusCode.OK, "{\"webPages\":");
            case "non-json":
                return new(HttpStatusCode.OK, "<html>Mock non-JSON response</html>", "text/html; charset=utf-8");
            case "wrong-shape":
                return new(HttpStatusCode.OK, "{\"unexpected\":[]}");
            case "upstream-error":
                return new(HttpStatusCode.InternalServerError, "{\"error\":{\"code\":\"MOCK_UPSTREAM_UNAVAILABLE\"}}");
            default:
                return new(HttpStatusCode.BadRequest, "{\"error\":{\"code\":\"INVALID_SCENARIO\",\"message\":\"Unknown mock scenario.\"}}");
        }
        return new(HttpStatusCode.OK, body.ToJsonString());
    }

    private static JsonObject Result(string url, int index) => new()
    {
        ["id"] = $"https://api.bing.microsoft.com/api/v7/#WebPages.{index}",
        ["name"] = $"Mock search result {index + 1}",
        ["url"] = url,
        ["displayUrl"] = url,
        ["snippet"] = "Synthetic search result. No request is sent to Bing.",
        ["dateLastCrawled"] = "2026-11-05T04:00:00Z",
        ["language"] = "ja",
        ["isFamilyFriendly"] = true,
        ["isNavigational"] = false
    };

    private static JsonObject RankingItem(int index) => new()
    {
        ["answerType"] = "WebPages",
        ["resultIndex"] = index,
        ["value"] = new JsonObject { ["id"] = $"https://api.bing.microsoft.com/api/v7/#WebPages.{index}" }
    };
}
