# Azure deployment plan

Status: Deployed

## 1. Goal

Deploy the existing .NET mock and English-only APIM guard to a new isolated test environment.
Do not modify the existing rg-ts-resources resources.

## 2. Approved context

- Subscription: a5095cf8-c1ec-4a7e-9ee7-22103870844b.
- Region: japaneast.
- Resource group: rg-bing-guard-demo-20261110.
- User approved Consumption APIM, on-demand Flex Functions, LRS Storage, workspace-based
  Application Insights, and five-minute log alerts with email notifications.
- Initial estimate was USD 3-10/month. User additionally approved private networking after
  the subscription forced Storage public access off. Revised light-use estimate: USD 11-18/month,
  not a spending cap, including approximately USD 7.80/month for one private endpoint and DNS zone.
- Notification recipient is supplied at deployment time; do not persist it in source or reports.
- Final state: keep test resources and alerts enabled, guard mode enforce.

## 3. Components and recipe

- Existing .NET 10 isolated HTTP Function.
- Existing APIM guard and mock API Bicep configuration.
- Recipe: Bicep plus Azure CLI / Functions Core Tools publication.
- New infrastructure: one Storage account, one Flex plan and Function App, one Consumption APIM,
  one workspace, one Application Insights component, one Action Group and one log alert.
- Two APIM test products and product-scoped subscriptions for attribution tests.
- Dedicated VNet, delegated Function subnet, one Blob private endpoint and private DNS zone/link.
  No NAT Gateway or paid DNS Resolver.

## 4. Safety

- No production resources, subscription switches, SKU upgrades, or resource deletion.
- User explicitly requested SecurityControl=Ignore on this isolated RG and identity-protected
  Storage Internet access after private-network publication still failed.
  Keep anonymous access and shared-key access disabled.
- Keep secrets in process memory or Azure secret settings; never print them.
- All requests use synthetic search terms.
- Backends call mock data only, not real Bing.

## 5. Preparation

- [x] User approved subscription, region, isolated resource creation, estimated costs and notification testing.
- [x] Check provider readiness, regional availability and capacity.
- [x] Generate isolated environment template.
- [x] Validate actual template, package, tests and permissions.
  - [x] Core validation: CLI, authentication, Bicep build, ARM validation and what-if.
  - [x] Lint new environment and monitoring templates.
  - [x] Azure Policy validation through ARM provider validation.

## 6. Deployment and verification

- [x] Provision isolated base resources.
- [x] Publish .NET Function and verify readiness.
- [x] Apply APIM configuration, products, telemetry and alert.
- [x] Test live pass, English replacement, empty/error bypass, monitor and off.
- [x] Verify product/instance trace metadata and alert activation.
- [x] Leave enforce enabled and report endpoint URLs and any unverified behaviors.

## 7. Validation proof

Preflight evidence (2026-11-10):

- Azure CLI confirms Owner at the approved subscription scope.
- Microsoft.Web, Storage, ApiManagement, Insights and OperationalInsights are registered.
- Japan East is returned by list-flexconsumption-locations; .NET 10.0 and 512 MB are supported.
- Storage quota CLI: 2 accounts currently used, limit 250; adding one results in 3.
- Microsoft.Web quota/usage endpoints expose classic SKU counters but not Flex regional memory.
  The new app is capped at five 512 MB instances; ARM provider validation must confirm deployability.
- Resource group does not exist; existing test resources remain untouched.
- Release publish succeeded; 365 original policy expression/branch assertions passed.
- Infrastructure follows the official C# Functions v1.0.0 template's AVM/UAMI/RBAC patterns.
- All three new templates compiled successfully using official AVM modules.
- Official validate-deployment.ps1 completed: CLI/auth/build/provider validation/what-if all PASS.
- Subscription what-if: Create 14, Modify 0, Delete 0. No existing resource changes.
- Provider validation accepted the new Flex configuration and no Azure Policy denial was reported.
- Both proposed APIM and Function names are globally available.
- Initial environment provisioning succeeded after using the Insights module output rather than
  prematurely reading the new component.
- Actual subscription policy StorageAccount_PublicNetwork_Modify disables Storage public access.
  Function publication therefore returned 403; the user subsequently explicitly requested
  the isolated test-RG exemption described in section 4.
- User approved the official template's private networking path and its additional costs.
- Private networking was deployed and retained; it did not resolve publication.
- The explicitly requested RG tag and Storage public access change resolved publication.
- Existing private endpoint/DNS resources remain billable; no deletion was requested.
- Function smoke tests: good=200/2 results, mixed=200/3 results, error=500, unauthenticated=401.
- APIM sandbox required removing exception-filter syntax and the unsupported UriKind enum;
  original XML expression/branch tests still pass (365 assertions).
- Test-Apim.ps1: all 24 live gateway cases passed; final mode enforce.
- Log Analytics confirms Product A/B, instance a/b, monitor/enforce, and backend TraceIds.
- The initial live matrix produced 18 detection traces and metric total 18.
- Three actual Azure log alert instances reached Fired at 2026-11-10T08:03:19Z.
- Configured alert: enabled, PT5M evaluation/window, PT1H action mute.
- Email inbox delivery and a complete one-hour suppression/re-notification cycle are not verified.
- Final endpoint: https://apim-bing-guard-261110-844b.azure-api.net/bing-test/search.
- Final sample: HTTP 200, X-Bing-Guard=blocked, one English result, language=en.
- Unauthenticated Function and APIM calls both return 401.
- Re-deploying the test base must retain enableTestStoragePublicAccess=true to preserve
  the explicitly approved exception. Private networking resources remain retained and billable.
