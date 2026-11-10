Bing mock (.NET 10 isolated) + PDF-compatible APIM guard
=======================================================

本仓库按照 2026-11-05 PDF 的方案实现；已替换旧版“异常一律返回 502”的行为。
仅返回合成数据，不调用 Bing，不需要 Bing API Key，不创建或修改真实搜索实例。
Azure 资源不会自动部署。现有工作区中的其他改动保持不变。

文档
----
docs\portal-step-by-step.ja.md
  日语 step by step：Azure Portal 创建环境、Cloud Shell 或 VS Code 发布 .NET Function、
  配置 APIM fragments/产品/订阅、Application Insights、告警、UI 测试及回滚。
docs\implementation.ja.md
  PDF 页码与交付物对照、实现契约、配置值、边界及上线前确认事项。
客户无需在本地安装 VS Code/.NET/Azure CLI：可将配套的 bing-domain-guard-function.zip
上传 Cloud Shell（Bash）并按日语手册 4.1 节发布；需要改代码时，也可在 Cloud Shell 构建源码 ZIP。

核心行为
--------
off：不检查、不改变响应、不记录 guard 日志。
monitor（部署默认）：发现异常时保留原始响应体，记录日志/指标。
enforce：发现异常时将整个结果替换为 HTTP 200、Bing 形状的单条英语障碍提示。
按客户最新要求，提示标题和正文统一使用英语，不再根据 mkt/setLang 切换语言。

X-Bing-Guard：
  pass / blocked / detected-monitor-only / skipped
  off 不添加此头。skipped 是额外的诊断标记，响应体与状态保持原样。

检查 webPages.value[].url 和各结果 deepLinks[].url。
允许 hostname 包含 panasonic 或 technics，或等于例外域名/其子域。
关键词方案会允许 panasonic-campaign.example.com，这是 PDF 明确的设计选择。
如需严格域名模式，将关键词清空，在域名列表中枚举实际允许的域名。
HTTP 非 200、非 JSON、无 webPages、0 条结果、不支持的 JSON 形状：跳过而非替换。
JSON 解析失败也跳过并记录 BingGuardSkipped。无效 URL/缺少 URL 的结果按异常处理。
配置错误返回 500 并记录 BingGuardConfigurationError，不伪装成 Bing 故障。

未确定的正式配置
----------------
例外域名 exceptions.example、提示 URL https://www.panasonic.com/ 均为演示值，
不是已获批准的正式值。正式例外域名、提示文案/URL、通知邮箱必须由环境负责人确认。
Named Values 不得含半角双引号、反斜线、换行或 policy 表达式标记，详见日语文档。

本地运行（PowerShell，.NET 10 SDK + Functions Core Tools v4）
----------------------------------------------------------
  Copy-Item .\local.settings.example.json .\local.settings.json
  dotnet run --project .\BingDomainGuard.csproj

另开终端：
  curl.exe -i "http://localhost:7071/api/search?q=Test&mkt=ja-JP" -H "x-mock-scenario: mixed"

直接调用 Function 的 mixed 返回 200 和原始异常结果，这是供 APIM 检查的故障注入。
本地 Core Tools 默认不强制 Function Key；Azure 中需要 x-functions-key。
新 Functions SDK 的推荐启动入口是 dotnet run；不要在源码根目录用 func start --no-build。
纯 HTTP 测试不使用 Storage binding；如需要本地主机 Storage 健康检查也通过，请配置
可用的 Storage 或运行 Azurite 并设置 AzureWebJobsStorage=UseDevelopmentStorage=true。

测试
----
  dotnet test .\test\BingDomainGuard.Tests.csproj
  pwsh -NoProfile -File .\test\Test-Policy.ps1
  pwsh -NoProfile -File .\test\Test-Policy.ps1 -FunctionBaseUrl http://localhost:7071

Test-Policy.ps1 从实际 XML 提取并编译 C# 表达式、执行 choose 分支，
检查状态码、完整响应保留、单条替换结构、语言、ranking、日志元数据和指标调用。
本地 harness 不等于真实 APIM gateway，不模拟实际日志传输、邮件和父级 policy。

已部署的测试环境可运行真实网关测试（读取密钥但不输出，结束后恢复 enforce）：
  pwsh -NoProfile -File .\test\Test-Apim.ps1 -SubscriptionId <subscription-id> -ResourceGroup <test-rg> -ApimName <test-apim>
它会修改指定测试 APIM 的 guard 模式；不要指向生产实例。

可选 Bicep（只配置同一资源组内已有的 Function App/APIM）
--------------------------------------------------------
先通过 Cloud Shell 或 VS Code UI 发布本 Function，再执行：
  az deployment group create --resource-group <rg> --template-file .\infra\apim.bicep --parameters apimServiceName=<apim> functionAppName=<function> guardMode=monitor

模板创建/更新：
  6 个 bing-guard-* Named Values、1 个 Secret bing-function-key、
  bing-mock-function backend、2 个 fragments、
  /bing-test/search（guard）及 /bing-mock/search（无 guard）。
不创建 RG、Function App、APIM、产品/订阅、Insights、Workspace 或告警。
Function Key 是演示主机级函数密钥，不是 master key；轮换后须同步。
如存在旧示例 API，bing-domain-guard 的路径会从 /bing 改为 /bing-test；
旧 Named Values 不再引用，不自动删除。请先核对命名冲突和现有调用方。
生产环境只加入 fragments，不要用 mock 的路由/密钥策略覆盖现有 Bing API。

可选构建检查（将 <temporary-template-path> 替换为仓库外的临时文件路径）：
  az bicep build --file .\infra\apim.bicep --outfile <temporary-template-path>

新建隔离环境（需先批准费用、订阅及区域）
--------------------------------------
infra\deploy-test.bicep：订阅级入口，创建专用 RG 和 test-environment.bicep 资源。
infra\test-environment.bicep：Consumption APIM、.NET 10 Flex（512 MB，最多 5 个实例）、
  LRS Storage、托管身份/RBAC、Workspace/Insights、VNet、Blob Private Endpoint/Private DNS。
  Storage 禁用公网、共享密钥及匿名访问；私有终结点和 DNS 有持续费用。
infra\test-monitoring.bicep：在 apim.bicep 部署后应用，创建产品 A/B、专用订阅、
  托管身份 Insights logger、诊断、Action Group 和 5 分钟/1 小时抑制告警。
notificationEmail 为部署时传入的 secure 参数，不在源码中保存接收邮箱。
新建顺序：基础资源 -> 发布 Function -> apim.bicep -> test-monitoring.bicep -> Test-Apim.ps1。
仅在明确获得测试环境豁免批准时，可传 enableTestStoragePublicAccess=true：
  deploy-test.bicep 会给这个新建 RG 加 SecurityControl=Ignore，并启用需身份验证的 Storage 公网。
  默认 false；不会开放匿名访问或共享密钥，也不删除已有私有网络资源。
本次测试环境已按用户明确要求启用该选项；再次部署基础资源时应保留此参数，避免覆盖现状。

安全和运维边界
--------------
不要公开生产 API 的 mock 开关或无 guard API；测试资源使用专用产品与订阅。
不记录订阅密钥，不记录完整 URL；按 PDF 记录搜索词前 100 字符（可能涉及隐私），
上线前按数据治理要求移除 searchQuery 元数据并关闭诊断请求/响应 body 记录。
关键词匹配不是域名所有权验证；不跟踪重定向，不验证网页正文。
PDF 的替换只针对 webPages/deepLinks；其他结果集合不单独检查。
trace 不受 APIM 请求采样影响，但诊断详细度、摄取限额、网络及告警配置仍会影响通知。
新增资源会计费；邮件必须在目标 Azure 环境实际验证。
