using System.Net;
using System.Reflection;
using System.Text.Json.Nodes;
using BingDomainGuard;
using Microsoft.Azure.Functions.Worker;
using Xunit;

public sealed class MockSearchTests
{
    [Fact]
    public void GoodResponsePreservesQueryAndBingFields()
    {
        var response = MockSearch.Create("エアコン & APIM", "good");
        var body = JsonNode.Parse(response.Body)!;
        Assert.Equal(HttpStatusCode.OK, response.Status);
        Assert.Equal("SearchResponse", (string?)body["_type"]);
        Assert.Equal("エアコン & APIM", (string?)body["queryContext"]!["originalQuery"]);
        Assert.Equal(2, body["webPages"]!["value"]!.AsArray().Count);
        Assert.Contains("bing.com", (string?)body["webPages"]!["webSearchUrl"]);
        Assert.NotNull(body["rankingResponse"]);
    }

    [Theory]
    [InlineData("mixed", 3)]
    [InlineData("all-bad", 2)]
    [InlineData("exception", 2)]
    [InlineData("deep-link", 2)]
    [InlineData("lookalike", 2)]
    [InlineData("subdomain", 2)]
    [InlineData("suffix-attack", 2)]
    [InlineData("prefix-attack", 2)]
    [InlineData("userinfo-attack", 2)]
    [InlineData("path-attack", 2)]
    [InlineData("invalid-url", 2)]
    [InlineData("missing-url", 2)]
    [InlineData("empty-array", 0)]
    public void ScenariosLeaveGuardDecisionToApim(string scenario, int count)
    {
        var response = MockSearch.Create("q", scenario);
        Assert.Equal(HttpStatusCode.OK, response.Status);
        Assert.Equal(count, JsonNode.Parse(response.Body)!["webPages"]!["value"]!.AsArray().Count);
    }

    [Fact]
    public void ExceptionalFixturesAreDistinct()
    {
        Assert.Null(JsonNode.Parse(MockSearch.Create("q", "empty").Body)!["webPages"]);
        Assert.ThrowsAny<System.Text.Json.JsonException>(() => JsonNode.Parse(MockSearch.Create("q", "invalid-json").Body));
        Assert.StartsWith("text/html", MockSearch.Create("q", "non-json").ContentType);
        Assert.Null(JsonNode.Parse(MockSearch.Create("q", "wrong-shape").Body)!["webPages"]);
        Assert.Equal(HttpStatusCode.InternalServerError, MockSearch.Create("q", "upstream-error").Status);
        Assert.Equal(HttpStatusCode.BadRequest, MockSearch.Create("q", "unknown").Status);
    }

    [Theory]
    [InlineData("")]
    [InlineData("*.com")]
    [InlineData("https://panasonic.jp")]
    [InlineData("a..com")]
    [InlineData("panasonic.jp/path")]
    public void InvalidConfigurationFailsExplicitly(string domain) =>
        Assert.Throws<ArgumentException>(() => MockSearch.Create("q", "good", domain));

    [Fact]
    public void FixturesAreIndependentAndConfigurable()
    {
        MockSearch.Create("q", "mixed");
        var good = JsonNode.Parse(MockSearch.Create("q", "good", "contoso.com").Body)!;
        Assert.Equal("https://contoso.com/aircon/", (string?)good["webPages"]!["value"]![0]!["url"]);
        var exception = JsonNode.Parse(MockSearch.Create("q", "exception", exceptionDomain: "other.example").Body)!;
        Assert.Equal("https://support.other.example/b", (string?)exception["webPages"]!["value"]![1]!["url"]);
    }

    [Fact]
    public void FunctionRetainsProtectedGetRoute()
    {
        var method = typeof(Search).GetMethod(nameof(Search.Run))!;
        Assert.Equal("mockBingSearch", method.GetCustomAttribute<FunctionAttribute>()!.Name);
        var trigger = method.GetParameters()[0].GetCustomAttribute<HttpTriggerAttribute>()!;
        Assert.Equal(AuthorizationLevel.Function, trigger.AuthLevel);
        Assert.Equal("search", trigger.Route);
        Assert.NotNull(trigger.Methods);
        Assert.Equal(["get"], trigger.Methods);
    }
}
