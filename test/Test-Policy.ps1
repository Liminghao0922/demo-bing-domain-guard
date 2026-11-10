#Requires -Version 7.0
param([string]$FunctionBaseUrl)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

[xml]$inbound = Get-Content (Join-Path $PSScriptRoot '..\apim\fragments\bing-guard-inbound.xml') -Raw
[xml]$outbound = Get-Content (Join-Path $PSScriptRoot '..\apim\fragments\bing-guard-outbound.xml') -Raw
$expressions = [System.Collections.Generic.List[string]]::new()
$expressionIds = @{}
foreach ($document in @($inbound, $outbound)) {
    foreach ($node in $document.SelectNodes('//@* | //set-body | //message')) {
        $text = if ($node -is [System.Xml.XmlAttribute]) { $node.Value } else { $node.InnerText }
        if (!$text.Trim().StartsWith('@')) { continue }
        $text = $text.Trim()
        if ($expressionIds.ContainsKey($text)) { continue }
        $code = $text.Substring(2, $text.Length - 3)
        if ($text.StartsWith('@(')) { $code = "return $code;" }
        $code = [regex]::Replace($code, '"\{\{([^}]+)\}\}"', 'context.Settings["$1"]')
        $expressionIds[$text] = $expressions.Count
        $expressions.Add("case $($expressions.Count): { $code }")
    }
}

# Execute the shipped C# expressions and XML branches rather than a second guard implementation.
$source = @'
using System;
using System.Collections.Generic;
using Newtonsoft.Json;
public sealed class PolicyBody
{
    public string Json;
    public T As<T>(bool preserveContent = false)
    {
        if (!preserveContent) throw new InvalidOperationException("Response must be preserved.");
        return JsonConvert.DeserializeObject<T>(Json);
    }
}
public sealed class PolicyValues : Dictionary<string, string>
{
    public string GetValueOrDefault(string name, string fallback)
    {
        string value;
        return TryGetValue(name, out value) ? value : fallback;
    }
}
public sealed class PolicyResponse
{
    public int StatusCode = 200;
    public PolicyBody Body = new PolicyBody();
    public PolicyValues Headers = new PolicyValues();
}
public sealed class PolicyUrl { public PolicyValues Query = new PolicyValues(); }
public sealed class PolicyRequest { public PolicyUrl Url = new PolicyUrl(); public PolicyValues Headers = new PolicyValues(); }
public sealed class PolicyNamed { public string Name; }
public sealed class PolicyContext
{
    public PolicyResponse Response = new PolicyResponse();
    public PolicyRequest Request = new PolicyRequest();
    public PolicyNamed Product = new PolicyNamed { Name = "Product A" };
    public PolicyNamed Subscription = new PolicyNamed { Name = "Test A" };
    public Guid RequestId = Guid.NewGuid();
    public Dictionary<string, object> Variables = new Dictionary<string, object>();
    public PolicyValues Settings = new PolicyValues();
    public List<string> TraceMessages = new List<string>();
    public PolicyValues Metadata = new PolicyValues();
    public int MetricCount;
    public bool Returned;
}
public static class GuardExpressions
{
    public static object Evaluate(PolicyContext context, int expressionId)
    {
        switch (expressionId) { __EXPRESSIONS__ }
        throw new ArgumentOutOfRangeException("expressionId");
    }
}
'@
$source = $source.Replace('__EXPRESSIONS__', ($expressions -join "`n"))
$references = @((Get-ChildItem (Join-Path $PSHOME 'ref\*.dll')).FullName)
$references += [Newtonsoft.Json.JsonConvert].Assembly.Location
Add-Type -TypeDefinition $source -ReferencedAssemblies $references -CompilerOptions '/langversion:7.3', '/nowarn:1701'

function Get-PolicyValue([string]$Text, $Context) {
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('@')) {
        return [GuardExpressions]::Evaluate($Context, $expressionIds[$trimmed])
    }
    return $Text
}

function Invoke-PolicyNodes($Nodes, $Context) {
    foreach ($node in $Nodes) {
        if ($Context.Returned) { return }
        switch ($node.LocalName) {
            'set-variable' {
                $Context.Variables[$node.GetAttribute('name')] = Get-PolicyValue $node.GetAttribute('value') $Context
            }
            'choose' {
                foreach ($branch in $node.ChildNodes) {
                    if ($branch.LocalName -eq 'otherwise' -or
                        ($branch.LocalName -eq 'when' -and (Get-PolicyValue $branch.GetAttribute('condition') $Context))) {
                        Invoke-PolicyNodes $branch.ChildNodes $Context
                        break
                    }
                }
            }
            'set-header' {
                $headers = if ($script:section -eq 'inbound') { $Context.Request.Headers } else { $Context.Response.Headers }
                if ($node.GetAttribute('exists-action') -eq 'delete') {
                    [void]$headers.Remove($node.GetAttribute('name'))
                } else {
                    $headers[$node.GetAttribute('name')] = Get-PolicyValue $node.SelectSingleNode('value').InnerText $Context
                }
            }
            'set-body' { $Context.Response.Body.Json = Get-PolicyValue $node.InnerText $Context }
            'set-status' { $Context.Response.StatusCode = [int]$node.GetAttribute('code') }
            'trace' {
                $Context.TraceMessages.Add((Get-PolicyValue $node.SelectSingleNode('message').InnerText $Context))
                foreach ($metadata in $node.SelectNodes('metadata')) {
                    $value = Get-PolicyValue $metadata.GetAttribute('value') $Context
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        throw "Trace metadata '$($metadata.GetAttribute('name'))' must have a nonempty value."
                    }
                    $Context.Metadata[$metadata.GetAttribute('name')] = $value
                }
            }
            'emit-metric' {
                foreach ($dimension in $node.SelectNodes('dimension')) {
                    $value = Get-PolicyValue $dimension.GetAttribute('value') $Context
                    if ([string]::IsNullOrWhiteSpace($value)) {
                        throw "Metric dimension '$($dimension.GetAttribute('name'))' must have a nonempty value."
                    }
                }
                $Context.MetricCount++
            }
            'return-response' {
                Invoke-PolicyNodes $node.ChildNodes $Context
                $Context.Returned = $true
            }
            default { throw "Unsupported harness node: $($node.LocalName)" }
        }
    }
}

function Invoke-Guard {
    param([string]$Json, [string]$Mode = 'enforce', [string]$Keywords = 'panasonic,technics',
        [string]$Domains = 'exceptions.example', [string]$Market = 'ja-JP', [string]$SetLang = '',
        [string]$SorryUrl = 'https://www.panasonic.com/',
        [hashtable]$QueryOverrides = @{},
        [int]$Status = 200, [string]$ContentType = 'application/json; charset=utf-8')
    $context = [PolicyContext]::new()
    $context.Response.Body.Json = $Json
    $context.Response.StatusCode = $Status
    $context.Response.Headers['Content-Type'] = $ContentType
    $context.Response.Headers['BingAPIs-TraceId'] = 'mock-trace-id'
    $context.Request.Headers['Accept-Encoding'] = 'gzip'
    $context.Request.Url.Query['q'] = 'Test query'
    $context.Request.Url.Query['mkt'] = $Market
    $context.Request.Url.Query['setLang'] = $SetLang
    $context.Request.Url.Query['customconfig'] = 'instance-a'
    foreach ($pair in $QueryOverrides.GetEnumerator()) {
        if ($null -eq $pair.Value) {
            [void]$context.Request.Url.Query.Remove($pair.Key)
        } else {
            $context.Request.Url.Query[$pair.Key] = $pair.Value
        }
    }
    foreach ($pair in @{
        'bing-guard-mode' = $Mode
        'bing-guard-allowed-keywords' = $Keywords
        'bing-guard-allowed-domains' = $Domains
        'bing-guard-sorry-title' = 'Search is temporarily unavailable'
        'bing-guard-sorry-snippet' = 'We apologize for the inconvenience. Please try again later.'
        'bing-guard-sorry-url' = $SorryUrl
    }.GetEnumerator()) { $context.Settings[$pair.Key] = $pair.Value }
    $script:section = 'inbound'
    Invoke-PolicyNodes $inbound.DocumentElement.ChildNodes $context
    $script:section = 'outbound'
    Invoke-PolicyNodes $outbound.DocumentElement.ChildNodes $context
    return $context
}

$script:passed = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "${Name}: expected '$Expected', received '$Actual'." }
    $script:passed++
}
function New-Payload([object]$Url) {
    return @{
        _type = 'SearchResponse'
        queryContext = @{ originalQuery = 'Test query' }
        webPages = @{ webSearchUrl = 'https://www.bing.com/search?q=Test'; value = @(@{ url = $Url; deepLinks = @(@{ url = 'https://technics.com/' }) }) }
        rankingResponse = @{ mainline = @{ items = @(@{ answerType = 'WebPages'; resultIndex = 99 }) } }
        images = @{ value = @(@{ contentUrl = 'https://outside.example/image' }) }
    } | ConvertTo-Json -Depth 15 -Compress
}
foreach ($url in @('https://panasonic.jp/a', 'https://TECHNICS.COM/', 'https://panasonic.jp./a',
    'https://panasonic-campaign.example.com/', 'https://exceptions.example/', 'https://support.exceptions.example/')) {
    $json = New-Payload $url
    $context = Invoke-Guard $json
    Assert-Equal $context.Response.Headers['X-Bing-Guard'] 'pass' $url
    Assert-Equal $context.Response.Body.Json $json 'Pass preserves exact body'
    Assert-Equal $context.Request.Headers.ContainsKey('Accept-Encoding') $false 'Compression negotiation removed'
}
foreach ($url in @('https://outside.example/panasonic/', 'https://exceptions.example.outside.example/',
    'https://not-exceptions.example/', 'https://panasonic.jp@outside.example/',
    'https://user@panasonic.jp/', 'not-an-absolute-url', '//panasonic.jp/', 'javascript:panasonic',
    'https://panasonic.jp\@outside.example/', '', $null, 123)) {
    $context = Invoke-Guard (New-Payload $url)
    Assert-Equal $context.Response.StatusCode 200 'Blocked is HTTP 200'
    Assert-Equal $context.Response.Headers['X-Bing-Guard'] 'blocked' "Reject $url"
    $body = $context.Response.Body.Json | ConvertFrom-Json
    Assert-Equal $body.webPages.value.Count 1 'Exactly one replacement'
    Assert-Equal $body.webPages.totalEstimatedMatches 1 'Replacement count'
    Assert-Equal $body.webPages.value[0].language 'en' 'English fallback'
    Assert-Equal $body.webPages.value[0].name $context.Settings['bing-guard-sorry-title'] 'English title'
    Assert-Equal $body.webPages.value[0].snippet $context.Settings['bing-guard-sorry-snippet'] 'English snippet'
    Assert-Equal $body.webPages.value[0].url 'https://www.panasonic.com/' 'Configured safe URL'
    Assert-Equal $body.webPages.value[0].PSObject.Properties.Name.Count 9 'Standard result field count'
    Assert-Equal $body.webPages.value[0].isFamilyFriendly $true 'Family-friendly flag'
    Assert-Equal $body.webPages.value[0].isNavigational $false 'Navigational flag'
    Assert-Equal $body.webPages.value[0].displayUrl $body.webPages.value[0].url 'Display URL matches target'
    Assert-Equal $body.rankingResponse.mainline.items[0].value.id $body.webPages.value[0].id 'Ranking points to replacement'
    Assert-Equal $body.webPages.webSearchUrl 'https://www.bing.com/search?q=Test' 'Preserved search URL'
    Assert-Equal $body.queryContext.originalQuery 'Test query' 'Preserved query context'
    Assert-Equal $body.rankingResponse.mainline.items.Count 1 'Ranking rebuilt'
    Assert-Equal $body.rankingResponse.mainline.items[0].resultIndex 0 'Ranking index rebuilt'
    Assert-Equal $body.PSObject.Properties.Name.Contains('images') $false 'No external images'
    Assert-Equal $body.webPages.value[0].PSObject.Properties.Name.Contains('deepLinks') $false 'No deep links in replacement'
    Assert-Equal $context.Response.Headers['Cache-Control'] 'no-store' 'No-store replacement'
    Assert-Equal $context.TraceMessages.Contains('BingGuardTriggered') $true 'Trigger traced'
    Assert-Equal $context.Metadata['bingTraceId'] 'mock-trace-id' 'Backend TraceId retained'
    Assert-Equal $context.Metadata['productName'] 'Product A' 'Product attribution'
    Assert-Equal $context.Metadata['bingInstance'] 'instance-a' 'Instance attribution'
    Assert-Equal $context.MetricCount 1 'One metric per detection'
}
$deep = '{"webPages":{"value":[{"url":"https://panasonic.jp/","deepLinks":[{"url":"https://outside.example/"}]}]}}'
Assert-Equal (Invoke-Guard $deep).Response.Headers['X-Bing-Guard'] 'blocked' 'Deep link inspected'
$bad = New-Payload 'https://outside.example/'
$monitor = Invoke-Guard $bad -Mode monitor
Assert-Equal $monitor.Response.Body.Json $bad 'Monitor preserves exact body'
Assert-Equal $monitor.Response.Headers['X-Bing-Guard'] 'detected-monitor-only' 'Monitor marker'
Assert-Equal $monitor.MetricCount 1 'Monitor metric'
$off = Invoke-Guard $bad -Mode off
Assert-Equal $off.Response.Body.Json $bad 'Off preserves exact body'
Assert-Equal $off.TraceMessages.Count 0 'Off emits no logs'
Assert-Equal $off.Response.Headers.ContainsKey('X-Bing-Guard') $false 'Off adds no marker'
Assert-Equal $off.Request.Headers['Accept-Encoding'] 'gzip' 'Off leaves request unchanged'
foreach ($languages in @(@('en-GB', ''), @('', ''), @('en-GB', 'ja'), @('ja-JP', 'ja'))) {
    $context = Invoke-Guard $bad -Market $languages[0] -SetLang $languages[1]
    $result = ($context.Response.Body.Json | ConvertFrom-Json).webPages.value[0]
    Assert-Equal $result.language 'en' 'English language regardless of market/setLang'
    Assert-Equal $result.name $context.Settings['bing-guard-sorry-title'] 'English title regardless of market/setLang'
    Assert-Equal $result.snippet $context.Settings['bing-guard-sorry-snippet'] 'English snippet regardless of market/setLang'
}
foreach ($mode in @('monitor', 'enforce')) {
    foreach ($case in @(
        @{ value = $null; expected = 'unspecified' },
        @{ value = ''; expected = 'unspecified' },
        @{ value = '   '; expected = 'unspecified' },
        @{ value = '%20%20'; expected = 'unspecified' },
        @{ value = '+++'; expected = 'unspecified' },
        @{ value = '%09%0A'; expected = 'unspecified' },
        @{ value = 'ja-JP'; expected = 'ja-JP' },
        @{ value = 'en-GB'; expected = 'en-GB' },
        @{ value = '%2B'; expected = '%2B' },
        @{ value = '%2520'; expected = '%2520' }
    )) {
        $context = Invoke-Guard $bad -Mode $mode -QueryOverrides @{ mkt = $case.value }
        $expectedMarker = if ($mode -eq 'monitor') { 'detected-monitor-only' } else { 'blocked' }
        Assert-Equal $context.Metadata['market'] $case.expected 'Optional market metadata is nonempty'
        Assert-Equal $context.Response.StatusCode 200 'Optional market does not cause a gateway error'
        Assert-Equal $context.Response.Headers['X-Bing-Guard'] $expectedMarker 'Optional market preserves mode behavior'
        Assert-Equal $context.TraceMessages.Contains('BingGuardTriggered') $true 'Optional market still logs detection'
    }
    foreach ($empty in @($null, '', '   ', '%20%20', '+++')) {
        $context = Invoke-Guard $bad -Mode $mode -QueryOverrides @{ mkt = $empty; q = $empty; customconfig = $empty }
        Assert-Equal $context.Metadata['market'] 'unspecified' 'Missing market is explicit in logs'
        Assert-Equal $context.Metadata['searchQuery'] 'unspecified' 'Missing search query is explicit in logs'
        Assert-Equal $context.Metadata['bingInstance'] 'unknown' 'Missing instance is explicit in logs'
        Assert-Equal $context.Response.StatusCode 200 'Empty optional query parameters do not cause a gateway error'
        Assert-Equal $context.MetricCount 1 'Empty optional parameters do not prevent metric emission'
    }
}
foreach ($json in @('{}', '{"webPages":{"value":[]}}', '{"webPages":', '[]', '{"webPages":{"value":{}}}')) {
    $context = Invoke-Guard $json
    Assert-Equal $context.Response.Headers['X-Bing-Guard'] 'skipped' 'Untargeted response skipped'
    Assert-Equal $context.Response.Body.Json $json 'Skipped body preserved'
    Assert-Equal $context.MetricCount 0 'Skipped response is not a detection'
}
$errorResponse = Invoke-Guard '{"error":true}' -Status 500
Assert-Equal $errorResponse.Response.StatusCode 500 'Backend error status preserved'
Assert-Equal $errorResponse.Response.Body.Json '{"error":true}' 'Backend error body preserved'
Assert-Equal (Invoke-Guard '<html>error</html>' -ContentType 'text/html').Response.Headers['X-Bing-Guard'] 'skipped' 'Non-JSON skipped'
Assert-Equal (Invoke-Guard $bad -Mode typo).Response.StatusCode 500 'Invalid mode explicit failure'
Assert-Equal (Invoke-Guard $bad -Keywords '' -Domains '').Response.StatusCode 500 'Empty allow configuration explicit failure'
Assert-Equal (Invoke-Guard $bad -Domains '*.example').Response.StatusCode 500 'Invalid domain explicit failure'
Assert-Equal (Invoke-Guard $bad -SorryUrl 'javascript:alert(1)').Response.StatusCode 500 'Unsafe fallback URL explicit failure'
Assert-Equal (Invoke-Guard (New-Payload 'https://panasonic-campaign.example.com/') -Keywords '' -Domains 'panasonic.jp,technics.com').Response.Headers['X-Bing-Guard'] 'blocked' 'Domain-only mode rejects lookalikes'
Assert-Equal (Invoke-Guard (New-Payload 'https://support.panasonic.jp/') -Keywords '' -Domains 'panasonic.jp,technics.com').Response.Headers['X-Bing-Guard'] 'pass' 'Domain-only mode allows descendants'
Assert-Equal (Invoke-Guard (New-Payload 'https://EXCEPTIONS.EXAMPLE./') -Keywords '' -Domains ' Exceptions.EXAMPLE. , TECHNICS.com ').Response.Headers['X-Bing-Guard'] 'pass' 'Domain normalization'
$manyResults = @{ webPages = @{ value = @(1..12 | ForEach-Object { @{ url = "https://host$_.outside.example/" } }) } } |
    ConvertTo-Json -Depth 10 -Compress
$many = Invoke-Guard $manyResults
Assert-Equal $many.Metadata['violatedHosts'].Split(',').Length 10 'At most ten unique violation hosts'
Assert-Equal $many.Response.Headers['X-Bing-Guard'] 'blocked' 'Many violations still replace everything'

if ($FunctionBaseUrl) {
    $scenarios = @{
        good = 'pass'; mixed = 'blocked'; 'all-bad' = 'blocked'; exception = 'pass'
        'deep-link' = 'blocked'; lookalike = 'pass'; 'path-attack' = 'blocked'
        'suffix-attack' = 'blocked'; 'prefix-attack' = 'blocked'; 'userinfo-attack' = 'blocked'
        'invalid-url' = 'blocked'; 'missing-url' = 'blocked'; subdomain = 'pass'
        empty = 'skipped'; 'empty-array' = 'skipped'; 'upstream-error' = 'skipped'
        'non-json' = 'skipped'; 'invalid-json' = 'skipped'; 'wrong-shape' = 'skipped'
    }
    foreach ($scenario in $scenarios.Keys) {
        $response = Invoke-WebRequest "$($FunctionBaseUrl.TrimEnd('/'))/api/search?q=Test&mkt=ja-JP" `
            -Headers @{ 'x-mock-scenario' = $scenario } -SkipHttpErrorCheck
        $context = Invoke-Guard $response.Content -Status $response.StatusCode -ContentType ($response.Headers['Content-Type'] -join ',')
        Assert-Equal $context.Response.Headers['X-Bing-Guard'] $scenarios[$scenario] "Live Function: $scenario"
        Assert-Equal ($response.Headers['BingAPIs-TraceId'] -join ',').Length 32 'Mock TraceId header'
        Assert-Equal ($response.Headers['Cache-Control'] -join ',') 'no-store' 'Live no-store'
    }
}
Write-Output "$script:passed assertions passed (shipped C# expressions and XML branches; not an APIM gateway)."
