#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ApimName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$token = az account get-access-token --subscription $SubscriptionId --resource https://management.azure.com/ --query accessToken --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Unable to authenticate to ARM.' }
$armHeaders = @{ Authorization = "Bearer $token" }
$service = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$apiVersion = '2024-05-01'
$details = Invoke-RestMethod "$service`?api-version=$apiVersion" -Headers $armHeaders -TimeoutSec 60
$gateway = $details.properties.gatewayUrl
$keys = @{}
foreach ($product in @('a', 'b')) {
    $secrets = Invoke-RestMethod "$service/subscriptions/test-$product/listSecrets?api-version=$apiVersion" `
        -Method Post -Headers $armHeaders -TimeoutSec 60
    $keys[$product] = $secrets.primaryKey
}
$runId = "guard-live-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmss'))"
$rows = [System.Collections.Generic.List[object]]::new()

function Set-GuardMode([string]$Mode) {
    $body = @{ properties = @{ displayName = 'bing-guard-mode'; secret = $false; value = $Mode } } | ConvertTo-Json -Depth 5
    $null = Invoke-RestMethod "$service/namedValues/bing-guard-mode?api-version=$apiVersion" `
        -Method Put -Headers $armHeaders -ContentType 'application/json' -Body $body -TimeoutSec 60
}

function Get-SearchResponse([string]$Scenario, [string]$Product = 'a',
    [string]$Instance = 'demo-instance-a', [string]$Path = 'bing-test') {
    Invoke-WebRequest "$gateway/$Path/search?q=$runId&customconfig=$Instance&mkt=ja-JP&setLang=ja" `
        -Headers @{ 'Ocp-Apim-Subscription-Key' = $keys[$Product]; 'x-mock-scenario' = $Scenario } `
        -SkipHttpErrorCheck -TimeoutSec 75
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Wait-Mode([string]$Expected) {
    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        $response = Get-SearchResponse 'mixed'
        $actual = if ($response.Headers.ContainsKey('X-Bing-Guard')) { $response.Headers['X-Bing-Guard'] -join ',' } else { '' }
        if ($response.StatusCode -eq 200 -and $actual -ceq $Expected) { return }
        Start-Sleep -Seconds 5
    }
    throw "Mode propagation failed: expected '$Expected', HTTP $($response.StatusCode), guard '$actual'."
}

function Test-Scenario([string]$Scenario, [string]$Marker, [int]$Status = 200,
    [string]$Product = 'a', [string]$Instance = 'demo-instance-a') {
    $response = Get-SearchResponse $Scenario $Product $Instance
    $actualMarker = if ($response.Headers.ContainsKey('X-Bing-Guard')) { $response.Headers['X-Bing-Guard'] -join ',' } else { '' }
    Assert-True ($response.StatusCode -eq $Status) "$Scenario expected HTTP $Status, got $($response.StatusCode)."
    Assert-True ($actualMarker -ceq $Marker) "$Scenario expected guard '$Marker', got '$actualMarker'."
    $count = $null
    if ($Marker -eq 'blocked') {
        $body = $response.Content | ConvertFrom-Json
        $count = $body.webPages.value.Count
        $result = $body.webPages.value[0]
        Assert-True ($count -eq 1 -and $body.webPages.totalEstimatedMatches -eq 1) "$Scenario did not replace the entire result set."
        Assert-True ($result.name -ceq 'Search is temporarily unavailable') "$Scenario title is not the configured English title."
        Assert-True ($result.snippet -ceq 'We apologize for the inconvenience. Please try again later.') "$Scenario snippet is not English."
        Assert-True ($result.language -ceq 'en') "$Scenario did not remain English for ja-JP/setLang=ja."
        Assert-True ($result.url -ceq 'https://www.panasonic.com/') "$Scenario replacement target differs from the test configuration."
        Assert-True (!$response.Content.Contains('outside.example')) "$Scenario leaked a rejected result."
        Assert-True (($response.Headers['Cache-Control'] -join ',') -ceq 'no-store') "$Scenario replacement is cacheable."
    } elseif ($Scenario -in @('good', 'mixed', 'all-bad', 'exception', 'lookalike', 'subdomain')) {
        $count = ($response.Content | ConvertFrom-Json).webPages.value.Count
        if ($Scenario -eq 'mixed') {
            Assert-True ($count -eq 3 -and $response.Content.Contains('outside.example')) 'Monitor/off modified mixed results.'
        }
    }
    $rows.Add([pscustomobject]@{
        Scenario = $Scenario
        Product = $Product
        Instance = $Instance
        Http = $response.StatusCode
        Guard = $actualMarker
        Results = $count
    })
}

try {
    Set-GuardMode 'enforce'
    Wait-Mode 'blocked'
    foreach ($scenario in @('good', 'subdomain', 'exception', 'lookalike')) { Test-Scenario $scenario 'pass' }
    foreach ($scenario in @('mixed', 'all-bad', 'deep-link', 'path-attack', 'suffix-attack',
        'prefix-attack', 'userinfo-attack', 'invalid-url', 'missing-url')) { Test-Scenario $scenario 'blocked' }
    foreach ($scenario in @('empty', 'empty-array', 'non-json', 'invalid-json', 'wrong-shape')) { Test-Scenario $scenario 'skipped' }
    Test-Scenario 'upstream-error' 'skipped' 500

    $raw = Get-SearchResponse 'mixed' -Path 'bing-mock'
    Assert-True ($raw.StatusCode -eq 200 -and ($raw.Content | ConvertFrom-Json).webPages.value.Count -eq 3) 'Unguarded mock API is not returning three raw results.'
    $rows.Add([pscustomobject]@{ Scenario = 'unguarded-mixed'; Product = 'a'; Instance = 'demo-instance-a'; Http = $raw.StatusCode; Guard = ''; Results = 3 })

    Set-GuardMode 'monitor'
    Wait-Mode 'detected-monitor-only'
    Test-Scenario 'mixed' 'detected-monitor-only'
    Set-GuardMode 'off'
    Wait-Mode ''
    Test-Scenario 'mixed' ''
} finally {
    Set-GuardMode 'enforce'
}

Wait-Mode 'blocked'
Test-Scenario 'mixed' 'blocked' -Product 'b'
Test-Scenario 'mixed' 'blocked' -Instance 'demo-instance-b'
Write-Output "RunId: $runId"
$rows | Format-Table -AutoSize
Write-Output "$($rows.Count) live APIM cases passed. Final mode: enforce. Keys were not printed."
