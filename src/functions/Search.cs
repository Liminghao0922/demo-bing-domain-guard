using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

namespace BingDomainGuard;

public sealed class Search
{
    [Function("mockBingSearch")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "search")] HttpRequestData request)
    {
        var scenario = request.Headers.TryGetValues("x-mock-scenario", out var values)
            ? values.First()
            : request.Query["scenario"] ?? "good";
        var mock = MockSearch.Create(
            request.Query["q"] ?? "Azure",
            scenario,
            Environment.GetEnvironmentVariable("MOCK_ALLOWED_DOMAIN") ?? "panasonic.jp",
            Environment.GetEnvironmentVariable("MOCK_EXCEPTION_DOMAIN") ?? "exceptions.example");
        var response = request.CreateResponse(mock.Status);
        response.Headers.Add("Content-Type", mock.ContentType);
        response.Headers.Add("Cache-Control", "no-store");
        response.Headers.Add("BingAPIs-TraceId", Guid.NewGuid().ToString("N"));
        response.Headers.Add("X-Mock-Response", "true");
        await response.WriteStringAsync(mock.Body);
        return response;
    }
}
