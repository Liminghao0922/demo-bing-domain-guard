# Azure Portal / Cloud Shell で作る Bing 障害ガード検証環境 — Step by step

## 0. この手順の目的と前提

Azure Portal と Cloud Shell、または VS Code で、モック → APIM 判定 → 応答置換 → 検知ログ → 通知を確認します。
**お客様の PC に VS Code / .NET SDK / Azure CLI をインストールしなくても実施できます。**
推奨経路は Portal で環境を作成し、Cloud Shell で **git clone → .NET ビルド → ZIP 作成 → Function 発行**を行う方法です。
その後の APIM・監視設定は Portal で実施します。Bicep の実行は不要です。
診断の `metrics=true` は通常の設定画面にないため、Portal の「カスタムテンプレートのデプロイ」画面で設定します。

Cloud Shell に .NET 10 SDK がなければ、ユーザー領域に導入します。Functions Core Tools は不要です。
SDK の導入や GitHub アクセスができない場合は、事前ビルド済み ZIP をアップロードする代替経路も使用できます。
VS Code を利用する代替手順も掲載します。
**Portal のコードエディターだけで C# isolated Function を作成・発行することはできません。**

### 準備するもの

- 検証専用の Azure サブスクリプション/RG。リソース作成、APIM 設定変更、アラート/アクショングループ作成権限。
  例：検証 RG の Contributor。組織ポリシー/RBAC により追加権限が必要な場合があります。
- Cloud Shell 経路：ブラウザーと[ソースリポジトリ](https://github.com/Liminghao0922/demo-bing-domain-guard)へのアクセス権。
  GitHub / SDK / NuGet へ接続できること。接続制限がある場合の代替は提供者の
  `bing-domain-guard-function.zip`、または `bing-domain-guard-cloudshell-source.zip`。
- VS Code 経路を選ぶ場合のみ：ローカル .NET 10 SDK、Azure Functions Core Tools v4、VS Code、
  C# / Azure Functions / Azure Resources 拡張機能。Windows の Core Tools は公式 MSI 等を使用。
- 受信確認できる検証用メールアドレス。メールには検索語やキーを含めないでください。
- [本実装の仕様](./implementation.ja.md)を確認済みであること。

> **課金注意**：APIM、Functions、Storage、Log Analytics、Application Insights、アラート等は課金対象です。
> PDF 例は APIM Consumption ですが、作成可能な SKU/リージョンは契約により異なります。
> 利用可能でなければ承認を得て専用の Developer 等を選択し、作成画面の料金を確認します。
> 既存の本番 APIM/Function App へこのデモを発行しないでください。

### 名前の記録

| 項目                       | 例 / 記入欄                      |
| -------------------------- | -------------------------------- |
| リソースグループ           | rg-bing-guard-demo               |
| リージョン                 | 利用可能かつ承認済みのリージョン |
| Log Analytics              | law-bing-guard-demo              |
| Application Insights       | appi-bing-guard-demo             |
| Function App               | func-bing-guard-＜一意な文字列＞ |
| Storage                    | stbingguard＜一意な英数字＞      |
| APIM                       | apim-bing-guard-＜一意な文字列＞ |
| APIM の Insights ロガー名  | 作成後の実名を記録               |
| アクショングループ         | ag-bing-guard-demo               |
| テスト API 名 / URL suffix | bing-domain-guard / bing-test    |
| 比較用 API 名 / URL suffix | bing-mock / bing-mock            |

---

## 1. リソースグループを作成する

1. [Azure Portal](https://portal.azure.com/) にサインイン。
2. 上部の検索で **リソースグループ** → **作成**。
3. サブスクリプション、検証専用 RG 名、リージョンを入力。
4. **確認および作成** → **作成**。
5. 作成した RG を開き、本番 RG と異なることを確認。

## 2. Log Analytics / Application Insights を作成する

1. Portal 上部で **Log Analytics ワークスペース** → **作成**。
2. 手順 1 の RG と承認済みリージョンを選び、名前を入力して作成。
3. 上部で **Application Insights** → **作成**。
4. 同じ検証 RG を選択し、名前・リージョンを入力。
5. ワークスペースベースの構成で、先ほどの Log Analytics を選択して作成。
6. Insights の **使用量と推定コスト** → **カスタム メトリック (プレビュー)** →
   **ディメンションあり / With dimensions** を選択し保存。
7. Workspace のデータ保持期間、日次上限、閲覧権限を組織方針に合わせて設定。
   日次上限到達時は検知ログも欠損し得るため、上限の監視も検討。

## 3. .NET Function App を作成する

1. Portal 上部で **関数アプリ** → **作成**。
2. ホスティングは、例として **Flex Consumption** を選択。
   Linux の従来 Consumption は .NET 10 に対応しないため選択しません。
3. 検証 RG、一意な名前、利用可能なリージョンを入力。
4. ランタイムスタックを **.NET**、バージョンを **10 / isolated worker** にする。
   選択できなければ対応するリージョン/プランを選び直し、別バージョンのまま進めないでください。
5. Storage / デプロイ用 Storage の作成画面で、専用の Storage を作成または承認済みのものを選択。
6. ネットワークは検証の範囲で APIM から到達可能な設定にする。既存の本番ネットワークを変更しません。
7. Monitoring 画面で手順 2 の Application Insights を選択できる場合は指定。
   Function 自体の Insights 接続と、後述の APIM ロガー接続は別物です。
8. **確認および作成** → **作成**。
9. 作成後、**設定 → 環境変数**（旧 UI：構成）で次を追加し **適用**。| 名前                  | 値                 |
   | --------------------- | ------------------ |
   | MOCK_ALLOWED_DOMAIN   | panasonic.jp       |
   | MOCK_EXCEPTION_DOMAIN | exceptions.example |
10. ホスティングによって `FUNCTIONS_WORKER_RUNTIME` が表示される場合は `dotnet-isolated` を確認。
    Flex ではランタイムがサイト構成で管理されるため、非対応のアプリ設定を無理に追加しません。
11. Portal が作成した Storage / ランタイム / デプロイ設定は削除しません。

> **組織ポリシーで Storage の公開アクセスが禁止される場合**：
> 公開アクセスを再有効化して回避しないでください。Function の VNet 統合、
> Blob Private Endpoint と `privatelink.blob.core.windows.net` の DNS ゾーン/リンクが必要です。
> Function のデプロイ用マネージド ID に Storage Blob Data Owner を付与し、
> Storage の共有キーは無効のままにします。プライベートエンドポイントと DNS は追加料金です。
> 本プロジェクトの [隔離環境テンプレート](../infra/test-environment.bicep) はこの構成に対応しています。

## 4. Function を発行する（Cloud Shell または VS Code）

### 4.1 Cloud Shell から発行する（ローカル開発環境がない場合・推奨）

以下のコマンドは **Azure Cloud Shell の Bash** で実行します。お客様の PC の PowerShell ではありません。
発行先は手順 3 で作成済みの **.NET 10 isolated / Flex Consumption の検証専用 Function App** です。
既存アプリ全体を更新するため、他の関数があるアプリや本番アプリへ発行しないでください。

#### 4.1.1 Cloud Shell を開き、対象を確認する

1. Portal 上部の **Cloud Shell（`>_`）** を選択し、シェルを **Bash** にする。
2. 初回の案内で、短時間の検証なら **ストレージアカウントをマウントしない**一時セッションも選択可能です。
   この場合はセッション終了後にファイルが消えるため、作業完了まで同じセッションを使用します。
   永続ストレージを作成する場合は組織ポリシーと追加費用を確認してください。
3. Cloud Shell は通常 Portal と同じアカウントで認証済みです。以下を順に実行します。

```bash
set -euo pipefail

read -r -p "Subscription ID: " SUBSCRIPTION_ID
read -r -p "Resource group: " RESOURCE_GROUP
read -r -p "Function App name: " FUNCTION_APP
: "${SUBSCRIPTION_ID:?Subscription ID is required}"
: "${RESOURCE_GROUP:?Resource group is required}"
: "${FUNCTION_APP:?Function App name is required}"

az account set --subscription "$SUBSCRIPTION_ID"
az account show --query '{subscription:name,id:id}' --output table

APP_ID=$(az functionapp show \
  --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP" \
  --query id --output tsv)

az rest --method get \
  --url "https://management.azure.com${APP_ID}?api-version=2024-11-01" \
  --query '{name:name,state:properties.state,host:properties.defaultHostName,runtime:properties.functionAppConfig.runtime}' \
  --output json

WORKDIR=$(mktemp -d "$HOME/bing-guard-cloudshell.XXXXXX")
```

4. サブスクリプション、アプリ名、ランタイム `dotnet-isolated / 10.0` を確認。
   想定と異なる場合は発行せず、対象を修正します。
5. 通常は手順 4.1.2 で GitHub からソースを取得し、手順 4.1.3 でビルドします。
   事前ビルド済み ZIP を使う場合は、4.1.2 の代替手順から 4.1.4 へ進みます。

#### 4.1.2 git clone でコードを取得する（推奨）

1. 同じ Bash セッションで次を実行します。ソース ZIP のダウンロードやアップロードは不要です。

```bash
git clone --branch main --single-branch \
  https://github.com/Liminghao0922/demo-bing-domain-guard.git \
  "$WORKDIR/source"

SOURCE_DIR="$WORKDIR/source"
test -f "$SOURCE_DIR/BingDomainGuard.csproj"
git -C "$SOURCE_DIR" rev-parse HEAD
```

2. 表示されたコミット ID を検証記録へ保存します。再現性が必要な場合は、ビルド前に
   `git -C "$SOURCE_DIR" checkout --detach <承認済みコミットIDまたはタグ>` で検証対象を固定し、
   再度 `rev-parse HEAD` で確認してください。
3. 非公開リポジトリの場合、Azure のサインインだけでは GitHub の権限は得られません。
   顧客に承認済みのアクセス権を付与し、組織指定の GitHub 認証を行ってください。
   GitHub CLI が利用可能なら `gh auth login --hostname github.com --git-protocol https --web` と
   `gh auth setup-git --hostname github.com` で認証できます。PAT を clone URL や文書に埋め込まないでください。
4. clone 後は **現在のソースからビルド**します。リポジトリ内にある既存の ZIP を使って代用すると、
   ソースの修正が反映されない場合があります。
5. 手順 4.1.3 へ進みます。

**代替 A：GitHub へ接続できない場合はソース ZIP をアップロード**

Cloud Shell のツールバー → **ファイルのアップロード/ダウンロード → アップロード**で、
提供者の `bing-domain-guard-cloudshell-source.zip` をアップロードします。
clone を実施していない同じセッションで、次を実行して 4.1.3 へ進みます。

```bash
unzip "$HOME/bing-domain-guard-cloudshell-source.zip" -d "$WORKDIR/source"
SOURCE_DIR="$WORKDIR/source"
test -f "$SOURCE_DIR/BingDomainGuard.csproj"
```

ZIP のルートには `BingDomainGuard.csproj` / `Program.cs` / `host.json` / `src` が必要です。
`local.settings.json`、キー、接続文字列は含めません。

**代替 B：ビルドできない場合は発行済み形式の ZIP をアップロード**

提供者の `bing-domain-guard-function.zip` を同じアップロード UI で送信し、以下を実行して
**4.1.3 をスキップし、4.1.4 へ進みます**。Linux x64 / .NET 10 用のコンパイル済み ZIP が必要です。

```bash
PACKAGE="$HOME/bing-domain-guard-function.zip"
test -f "$PACKAGE"
```

アップロードの表示パスが異なる場合は実際のパスへ修正してください。
GitHub の **Download ZIP** はソースの ZIP であり、そのまま Function へ発行できません。

#### 4.1.3 Cloud Shell 上で .NET 10 をビルドし、発行用 ZIP を作成する

1. .NET 10 SDK を確認し、なければ公式スクリプトを使って **Cloud Shell のユーザー領域だけ**へ導入します。
   PC 側へのインストールや `sudo` は不要です。手順 4.1.2 の `SOURCE_DIR` を使用します。

```bash
test -f "$SOURCE_DIR/BingDomainGuard.csproj"

if ! dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
  curl -fsSL https://dot.net/v1/dotnet-install.sh \
    -o "$WORKDIR/dotnet-install.sh"
  bash "$WORKDIR/dotnet-install.sh" \
    --channel 10.0 --install-dir "$HOME/.dotnet-bing-guard"
  export DOTNET_ROOT="$HOME/.dotnet-bing-guard"
  export PATH="$DOTNET_ROOT:$PATH"
fi

dotnet --list-sdks
dotnet publish "$SOURCE_DIR/BingDomainGuard.csproj" \
  --configuration Release --runtime linux-x64 --self-contained false \
  --output "$WORKDIR/publish" --nologo

PACKAGE="$WORKDIR/bing-domain-guard-function.zip"
python3 - "$WORKDIR/publish" "$PACKAGE" <<'PY'
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root).as_posix())
print("Deployment ZIP created.")
PY
```

2. SDK / NuGet のダウンロードが組織のネットワーク制限で失敗する場合は、制限を迂回せず許可を確認するか、
   手順 4.1.2 の「代替 B」を使用します。
3. ZIP に親の `publish` フォルダーを含めず、`.azurefunctions` も省略しません。
   上記の処理は隠しフォルダーを含めて、発行フォルダーの **中身だけ**を ZIP 化します。
4. 次の 4.1.4 でパッケージの構造を確認し、Function へ発行します。

#### 4.1.4 ZIP を検査して発行する

```bash
python3 - "$PACKAGE" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set(archive.namelist())
    required = {"host.json", "worker.config.json", "BingDomainGuard.dll"}
    if not required.issubset(names):
        raise SystemExit("Use the compiled deployment ZIP, not the source ZIP or a ZIP with a parent folder.")
    if not any(name.startswith(".azurefunctions/") for name in names):
        raise SystemExit("The deployment ZIP is missing .azurefunctions.")
    if any(name.rsplit("/", 1)[-1] == "local.settings.json" for name in names):
        raise SystemExit("Do not deploy local.settings.json.")
print("Deployment ZIP structure verified.")
PY

read -r -p "Re-enter the test Function App name to confirm overwrite: " CONFIRM_APP
if [[ "$CONFIRM_APP" != "$FUNCTION_APP" ]]; then
  echo "Names do not match. Deployment cancelled." >&2
  exit 1
fi

az functionapp deployment source config-zip \
  --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP" \
  --src "$PACKAGE" --build-remote false --timeout 600 --output none

az functionapp function list \
  --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP" \
  --query '[].{name:name,language:language}' --output table
```

- `mockBingSearch` と `dotnet-isolated` が表示されることを確認し、Portal の関数一覧も更新します。
- Flex では Azure CLI が対応するマネージドパッケージ発行方式を選択します。
  **`WEBSITE_RUN_FROM_PACKAGE` は追加しません。**
- コンパイル済み ZIP のため `--build-remote false` とし、リモートでの再ビルドは要求しません。
- `403` の場合は RBAC、デプロイ用 Storage の認証とネットワーク、SCM エンドポイントへの到達性を確認します。
  Private Endpoint のみの SCM へは通常の Cloud Shell から到達できない場合があり、
  VNet 接続された承認済みの実行環境が必要です。Cloud Shell はネットワーク制限を回避する機能ではありません。
- キーや接続文字列をコマンドへ直書きしたり、デプロイログを無加工で共有したりしないでください。

#### 4.1.5 Cloud Shell で Function 単体を確認する

以下はキーをメモリー内で取得し、正常 2 件・混在 3 件を確認します。`set -x` は使用しません。

```bash
FUNCTION_HOST=$(az rest --method get \
  --url "https://management.azure.com${APP_ID}?api-version=2024-11-01" \
  --query properties.defaultHostName --output tsv)

FUNCTION_KEY=$(az functionapp keys list \
  --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP" \
  --query functionKeys.default --output tsv)
: "${FUNCTION_KEY:?Unable to obtain the Function key}"

for SCENARIO in good mixed; do
  RESPONSE_FILE="$WORKDIR/$SCENARIO.json"
  HTTP_CODE=$(curl --silent --show-error \
    --output "$RESPONSE_FILE" --write-out '%{http_code}' \
    --header "x-functions-key: $FUNCTION_KEY" \
    "https://${FUNCTION_HOST}/api/search?q=cloud-shell-check&scenario=${SCENARIO}")
  EXPECTED_COUNT=2
  if [[ "$SCENARIO" == "mixed" ]]; then EXPECTED_COUNT=3; fi

  python3 - "$RESPONSE_FILE" "$HTTP_CODE" "$EXPECTED_COUNT" "$SCENARIO" <<'PY'
import json
import sys

if sys.argv[2] != "200":
    raise SystemExit(f"{sys.argv[4]}: unexpected HTTP status {sys.argv[2]}")
with open(sys.argv[1], encoding="utf-8") as response:
    body = json.load(response)
if len(body["webPages"]["value"]) != int(sys.argv[3]):
    raise SystemExit(f"{sys.argv[4]}: unexpected result count")
print(f"{sys.argv[4]}: HTTP 200, {sys.argv[3]} results - passed")
PY
done
unset FUNCTION_KEY
```

Function 直アクセスの `mixed` は 200・3 件のままです。APIM の置換確認は手順 10 で行います。
完了後は以下の「Function 単体を UI で確認」へ進むか、手順 5 以降の Portal 設定へ進みます。
一時セッションを閉じると、アップロードした ZIP・SDK・作業ファイルは消えますが、
**Azure に発行した Function は残ります。**

### 4.2 VS Code UI から発行する（代替経路）

1. VS Code の **ファイル → フォルダーを開く** で、このリポジトリを開く。
2. ワークスペースを信頼する前に内容を確認。必要な拡張機能をインストール。
3. **ターミナル → タスクの実行 → test-function** を選択。
4. タスク出力でテストが成功することを確認。SDK が見つからなければ .NET 10 SDK の導入後に VS Code を再起動。
5. **ターミナル → ビルドタスクの実行** で `publish-function` を実行。
6. Explorer に `publish` が生成され、`host.json`、`.azurefunctions`、`worker.config.json`、
   アプリ DLL があることを確認。`local.settings.json` とテストコードは公開しません。
7. 左の **Azure** アイコン → **Resources** から Azure にサインイン。
8. 対象サブスクリプション → **Function App** → 手順 3 のアプリを選ぶ。
9. 対象を右クリック → **Deploy to Function App... / 関数アプリにデプロイ**。
   またはコマンドパレットの **Azure Functions: Deploy to Function App...** を使用。
10. 対象アプリ名が検証専用であることを再確認し、上書き確認を承認。
    発行はアプリ全体を更新するため、他の関数があるアプリを選ばないでください。
11. ワークスペースの設定で `publish-function` が pre-deploy タスク、
    `publish` が公開フォルダーとして指定されています。ソース一式を zip にして送らないでください。
12. Azure 出力ペインで発行成功を確認し、Portal を再読み込み。
13. 関数一覧に **mockBingSearch** が表示されることを確認。

### Function 単体を UI で確認

1. 関数 **mockBingSearch** → **コードとテスト / Test/Run**。
2. Method=GET、Query に `q=テスト`、`mkt=ja-JP`。
3. Header に `x-mock-scenario=good` を追加し **実行**。
4. HTTP 200、`webPages.value` の 2 件を確認。
5. `x-mock-scenario=mixed` に変更して再実行。
6. HTTP 200、社内 2 件＋社外 1 件の合計 3 件を確認。
   **Function 単体では置換しない**のが正しい動作です。
7. `BingAPIs-TraceId` があることを確認。これはモック ID です。
8. Portal が CORS 許可を求める場合、表示された現在の Portal オリジンだけを検証用に許可。
   `*` を安易に追加せず、不要になった許可は削除。
9. Test/Run がホスティングの UI で使えない場合は、VS Code Azure ツリーで関数を右クリック →
   **Execute Function Now...**、または手順 8 の APIM Test UI を使用します。

## 5. APIM を作成する

1. Portal 上部で **API Management サービス** → **作成**。
2. 検証 RG、一意なサービス名、リージョン、組織名、管理者メールを入力。
3. 承認済み SKU を選択し、**確認および作成** → **作成**。
4. プロビジョニング完了後、概要の Gateway URL を記録。
5. 以下はこの APIM だけで実施します。既存の本番 APIM と画面を取り違えないでください。

## 6. 7 個の Named Values と backend を登録する

### 6.1 ガード用 Named Values（6 個）

APIM → **API → 名前付き値 / Named values → 追加**。
以下の **名前と表示名を同じ値**にし、種類=Plain / Secret オフで作成します。

| 名前 / 表示名               | 検証値                                                      |
| --------------------------- | ----------------------------------------------------------- |
| bing-guard-mode             | monitor                                                     |
| bing-guard-allowed-keywords | panasonic,technics                                          |
| bing-guard-allowed-domains  | exceptions.example                                          |
| bing-guard-sorry-title      | Search is temporarily unavailable                           |
| bing-guard-sorry-snippet    | We apologize for the inconvenience. Please try again later. |
| bing-guard-sorry-url        | https://www.panasonic.com/                                  |

`exceptions.example` と案内 URL は **デモ用**。正式値として承認されたものではありません。
値に半角 `"`、バックスラッシュ、改行、`@(`、`@{`、`{{`、`}}` を含めないでください。
実値を適用する前に[設定制約](./implementation.ja.md#4-承認待ちの設定)を確認します。
お客様の追加要望により、障害案内のタイトルと本文は英語のみです。日本語用の値は作成しません。
既存環境では接尾辞なしの新しい値を先に作成し、承認済みの英語文言を設定してから fragment を更新します。
更新後、他の参照がないことを確認し、不要な旧言語別 Named Values を削除できます。

### 6.2 Function Key（1 個、Secret）

1. Function App → **関数 → アプリキー / App keys**。
2. **Function keys** の `default` をコピー。`_master` は使用しません。
3. APIM の名前付き値を追加し、名前/表示名を **bing-function-key**、種類=**Secret** とする。
4. キーを値に貼り付けて保存。キーのスクリーンショットやドキュメントへの貼り付けはしません。
5. 本番では単一関数専用キーや Entra 認証、ネットワーク制限、Key Vault 管理を検討。
   キーをローテーションした場合、この Secret も同期が必要です。

### 6.3 Backend

1. APIM → **API → バックエンド / Backends → 追加**。
2. 名前：**bing-mock-function**。
3. 種類：HTTP、Runtime URL：`https://＜Function の実際のホスト名＞/api`。
4. URL は Function の概要/関数 URL から確認。推測で古い `azurewebsites.net` 名を組み立てないでください。
5. TLS 証明書のチェーン/名前の検証を有効にして保存。
6. この backend にキーを別登録する必要はありません。後述の policy が Secret をヘッダーに設定します。

## 7. Policy fragments と 2 つの API を作成する

### 7.1 Fragments

1. APIM → **API → ポリシーフラグメント / Policy fragments → 作成**。
2. 名前 **bing-guard-inbound**。
3. [bing-guard-inbound.xml](../apim/fragments/bing-guard-inbound.xml) を `<fragment>…</fragment>` ごと貼り付けて保存。
4. 同様に **bing-guard-outbound** を作成し、
   [bing-guard-outbound.xml](../apim/fragments/bing-guard-outbound.xml) を貼り付けて保存。
5. 未定義 Named Value や式の検証エラーが出たら先に修正し、エラーを無視して進めないでください。

### 7.2 ガード付き API

1. APIM → **API → API の追加 → HTTP / Blank API**。
2. Display name：Bing guard test。
3. **Name：bing-domain-guard**、Web service URL：Function の `https://＜実ホスト＞/api`。
4. **API URL suffix：bing-test**、Protocol：HTTPS。
5. **Subscription required / サブスクリプションが必要**を有効にして作成。
6. **操作の追加**：Name=Search、Method=GET、URL=`/search`、保存。
7. API の **Design → All operations → ポリシーコードエディター（</>）** を開く。
8. 検証用の空 API に限り、[policy.xml](../apim/policy.xml) の全体を貼り付けて保存。
9. 公開 URL が `https://＜APIM gateway＞/bing-test/search` になることを確認。

### 7.3 比較用モック API（guard なし）

1. 別の Blank API を作成：Name=**bing-mock**、URL suffix=**bing-mock**。
2. HTTPS、Subscription required、同じ Function の Web service URL を設定。
3. GET `/search` を追加。
4. All operations に [mock-policy.xml](../apim/mock-policy.xml) を貼り付けて保存。
5. 公開 URL は `https://＜APIM gateway＞/bing-mock/search`。
6. 無 guard API も Function Key は APIM から送信し、クライアントには返しません。
7. この API は検証専用です。本番製品へ追加しないでください。

## 8. 製品 A / B とサブスクリプションを作成する

1. APIM → **API → 製品 / Products → 追加**。
2. Display name=**Product A**、ID=**product-a**、Published=有効、
   Subscription required=有効、承認が必要=検証方針に応じて設定。
3. 製品の API 一覧に **bing-domain-guard** と **bing-mock** を追加。
4. 同様に **Product B / product-b** を作成し、両 API を追加。
5. APIM → **サブスクリプション → 追加**。
6. Name=**Test A**、Scope=**Product**、Product=**Product A**、State=Active。
7. 同様に **Test B** を **Product B** スコープで作成。
8. Test A/B のキーを必要時だけ表示。公開文書やコードへ保存しません。

> 製品別通知を確認する際は all-APIs の built-in キーや API-scoped キーを使わないでください。
> `context.Product` が空になり `productName=unassigned` となるためです。

## 9. APIM と Application Insights を接続する

### 9.1 ロガーの接続

1. APIM → **監視 → Application Insights → 追加**。
2. 手順 2 の Insights リソースを選択し保存。
3. 作成された **APIM ロガーのリソース名**を記録します。Insights 本体の名前とは必ずしも同じではありません。
4. UI で名前が確認できなければ、APIM の **テンプレートのエクスポート**を開き、
   `Microsoft.ApiManagement/service/loggers` の `name`、または API diagnostics の `loggerId` の末尾を確認。
   エクスポート内容には機密情報が含まれる可能性があるため共有/コミットしません。
5. 純粋な Portal ロガー追加は通常 instrumentation key ベースです。
   管理 ID + connection string が必須の環境では、別途承認済み IaC/REST 手順で接続してください。

### 9.2 API の診断

1. **API → bing-domain-guard → Settings → Diagnostics logs / 診断ログ**。
2. Application Insights を有効にし、先ほどのロガーを選択。
3. 検証中は Sampling=**100%**、Verbosity=**Error**、Always log errors=有効。
4. Frontend / Backend の request / response body 記録サイズをすべて **0 bytes**、
   記録ヘッダーを空にします。Function Key や Subscription Key を指定しません。
5. 保存。APIM の「診断設定」から Workspace へ送る一般リソースログとは異なります。

### 9.3 カスタムメトリックを UI から有効にする

通常の診断編集画面には `metrics=true` がない場合があります。
この場合も CLI は不要です。

1. Portal 上部で **カスタムテンプレートのデプロイ / Deploy a custom template** を開く。
2. **エディターで独自のテンプレートを作成** → **ファイルの読み込み**。
3. [apim-diagnostics.arm.json](../infra/apim-diagnostics.arm.json) を選択し保存。
4. 対象は **APIM と同じ検証 RG**。
5. パラメーター：
   - `apimServiceName`：APIM の名前。
   - `apiName`：**bing-domain-guard**（表示名や URL suffix ではない）。
   - `loggerName`：手順 9.1 で記録した APIM ロガー名。
6. **確認および作成** → **作成**。完了を確認。
7. このテンプレートは検証 API の診断を更新し、
   Error / 100% / 本文とヘッダー記録なし / custom metrics 有効にします。
8. **本番の既存診断へそのまま適用しないでください。** 本番では既存設定を保持して `metrics` を追加します。

## 10. UI で応答とログをテストする

### 10.1 共通の実行方法

1. APIM → **API → bing-domain-guard → Test → GET /search**。
2. Query parameters を追加：
   - `q`：テスト用の検索語。
   - `customconfig`：**demo-instance-a**。
   - `mkt`：**ja-JP**。
3. Headers に **x-mock-scenario** を追加し、下表のシナリオ値を指定。
4. Subscription の選択 UI があれば **Test A / Product A** を指定。
   なければ **Ocp-Apim-Subscription-Key** に Test A のキーを 1 つだけ指定。
   自動の組み込みキーと二重送信していないことを確認。
5. **Send / 送信**。
6. HTTP status、**X-Bing-Guard**、Response body、`BingAPIs-TraceId` を確認。
7. 初期値は monitor です。まず `mixed` が **detected-monitor-only / 3 件のまま**となることを確認。
8. Named Values で **bing-guard-mode=enforce** に変更して保存。
9. 設定が gateway に反映されるまで待ち、以下を確認します。
   「保存直後に必ず即時反映」ではなく、複数リージョン等への伝播時間があります。

### 10.2 enforce の必須テスト

| #  | x-mock-scenario            | HTTP          | X-Bing-Guard | 本文の確認                           |
| -- | -------------------------- | ------------- | ------------ | ------------------------------------ |
| 1  | good                       | 200           | pass         | Panasonic / Technics の 2 件、元本文 |
| 2  | mixed                      | 200           | blocked      | 英語の障害案内 **1 件のみ**    |
| 3  | all-bad                    | 200           | blocked      | 障害案内 1 件のみ                    |
| 4  | empty                      | 200           | skipped      | webPages なしの元本文                |
| 5  | empty-array                | 200           | skipped      | value=[]、元本文                     |
| 6  | exception                  | 200           | pass         | exceptions.example とその子ドメイン  |
| 7  | path-attack                | 200           | blocked      | パスの panasonic では許可しない      |
| 8  | lookalike                  | 200           | pass         | キーワード方式の意図した挙動         |
| 9  | upstream-error             | **500** | skipped      | 元エラー本文。案内へ置換しない       |
| 10 | deep-link                  | 200           | blocked      | deepLinks の外部 URL でも発動        |
| 11 | suffix-attack              | 200           | blocked      | 例外ドメインの偽後方一致を拒否       |
| 12 | prefix-attack              | 200           | blocked      | 例外ドメインの偽前方一致を拒否       |
| 13 | userinfo-attack            | 200           | blocked      | userinfo を含む URL を拒否           |
| 14 | invalid-url / missing-url  | 200           | blocked      | 無効/欠落 URL を含むため置換         |
| 15 | non-json                   | 200           | skipped      | HTML のまま                          |
| 16 | invalid-json / wrong-shape | 200           | skipped      | 元本文のまま、skip 理由の trace      |

比較するときは **bing-mock → Test** で同じクエリ/シナリオ/キーを指定します。
`mixed` は 3 件のまま、X-Bing-Guard は追加されません。

### 10.3 言語・ランキング・サイト表示

1. `mixed`、`mkt=en-GB`、`setLang` なし → 英語タイトル/本文、`language=en`。
2. `mkt=ja-JP`、`setLang=ja` → 同じ英語タイトル/本文、`language=en`。
3. `mkt` と `setLang` なし → 同じ英語。言語切替は行いません。
4. `webPages.totalEstimatedMatches=1`、`webPages.value` の要素数=1 を確認。
5. 元の `queryContext` と `webSearchUrl` が保持されることを確認。
6. `rankingResponse.mainline.items` が 1 件、`resultIndex=0`、
   `value.id` が置換結果の `id` と一致することを確認。
7. deepLinks、サムネイル、元の外部結果が残っていないことを確認。
8. `Cache-Control=no-store` を確認。
9. 各サイトの **ステージング環境だけ**を `/bing-test/search` へ接続し、
   結果 1 件、画像なし、案内 URL クリック、ページング、海外市場の表示を担当者が確認。
   API 側だけでポップアップや画面遷移は実装しません。
10. `mixed` のまま `mkt` を削除、空に変更、空白のみに変更しても、
    200 / blocked / 英語案内 1 件となり、ログの `market` は `unspecified` になることを確認。
    `q` / `customconfig` も省略した場合は、ログでそれぞれ `unspecified` / `unknown` と記録します。

### 10.4 monitor / off / 設定だけの変更

1. `bing-guard-mode=monitor` に保存し、`mixed`：
   **200、detected-monitor-only、3 件の元本文、検知ログあり**。
2. `bing-guard-mode=off` に保存し、`mixed`：
   **200、X-Bing-Guard 追加なし、3 件の元本文、このリクエストの guard ログなし**。
3. `bing-guard-mode=enforce` に戻す。
4. strict domain 方式の確認：
   - `bing-guard-allowed-keywords` を空（Portal が拒否する場合は半角スペース 1 個）。
   - `bing-guard-allowed-domains=panasonic.jp,technics.com,exceptions.example`。
   - `good` は pass、`subdomain` は pass、`lookalike` は blocked。
5. 終了後、既定のキーワード/例外値と **monitor** に戻す。
6. 値の変更履歴は Azure アクティビティログで確認します。

### 10.5 検知ログ / メトリック

1. Insights → **ログ / Logs**。スコープが **Application Insights 本体**であることを確認。
2. [guard-investigation.kql](../monitoring/guard-investigation.kql) をエディターへ貼り付けて **実行**。
3. 取り込み遅延があるため、送信直後に空でも数分待って再実行。
4. `Instance=demo-instance-a`、`Product=Product A`、TraceId、Hosts、Mode を確認。
5. 詳細確認用：

   ```kusto
   traces
   | where timestamp > ago(30m)
   | where message in ("BingGuardTriggered", "BingGuardSkipped", "BingGuardConfigurationError")
   | project timestamp, message, customDimensions
   | order by timestamp desc
   ```
6. monitor/enforce の検知に `subscriptionName=Test A` と `apimRequestId` があることを確認。
7. Test B のキーに変更して送信し、`Product B / Test B` になることを確認。
8. `customconfig=demo-instance-b` に変更し、別 Instance として記録されることを確認。
9. Insights → **メトリック**で、カスタム名前空間 **BingGuard**、
   メトリック **BingGuardTriggered**、集計=Sum を探して検知増加を確認。
   反映待ちが必要な場合があります。見えない場合は手順 2.6 と 9.3 を確認。

Workspace スコープの場合、テーブルは `AppTraces`、列は
`TimeGenerated / Message / Properties` になります。提供 KQL を無変更で実行する場合は Insights スコープを使います。

## 11. メールのアクショングループとアラートを作成する

### 11.1 アクショングループ

1. Portal → **Monitor → アラート → アクショングループ → 作成**。
2. 検証 RG、名前 **ag-bing-guard-demo**、短い表示名を設定。
3. **通知**で「電子メール/SMS メッセージ/プッシュ/音声」を選び、検証用メールを登録。
4. 共通アラートスキーマの設定を確認し、作成。
5. グループの **テスト**でメールが届くことを確認。
   これは通知経路の確認で、ガードからの通知成功を意味するものではありません。

### 11.2 ログ検索アラート

1. Insights → **ログ**で [guard-alert.kql](../monitoring/guard-alert.kql) を実行。
2. 直前に `mixed` を monitor/enforce で送っておくと、次元候補が表示されやすくなります。
3. **新しいアラートルール**を選択。Scope=対象の Application Insights。
4. Signal=**カスタムログ検索 / Custom log search**。
5. クエリは提供 KQL。測定=**テーブル行数 / Table rows**、
   集計種類=Count、集計粒度/参照期間=**5 分**。
6. Operator=**Greater than**、Threshold=**0**。
7. Evaluation frequency=**5 分**。
8. **ディメンションで分割 / Split by dimensions**：
   - **BingInstance**
   - **ProductName**
   - 各次元で全値と **将来のすべての値を含める**を選択。
   - TraceId、時刻、検索語等を次元に追加しません。
9. 判定は **1 回中 1 回**。
10. Actions で手順 11.1 のグループを指定。
11. Details で名前・承認済み重要度（例 Sev 2）を設定。
12. **自動的にアラートを解決 / Automatically resolve alerts をオフ**にし、stateless とする。
    **Mute actions / アクションをミュート**をオン、期間=**1 時間**。
13. この構成は「継続検知中も通知アクションを 1 時間抑止」の検証用設定です。
    stateful を選ぶと継続障害中の通知は初回のみとなる等、挙動が変わります。
14. 確認して作成し、ルールが Enabled であることを確認。

### 11.3 通知・抑止・分割を実際に確認

1. `monitor` または `enforce`、Test A、`demo-instance-a`、`mixed` を送信。
2. 通常は評価間隔＋取り込み遅延を待ちます。数秒で届く前提にしません。
3. アラート一覧と実メールで Instance / Product の次元が識別できることを確認。
4. 同じ組み合わせで `mixed` を繰り返し、評価が複数回行われても
   **1 時間以内の再通知が抑止**されるか記録。
5. その間もログ自体は継続記録されることを KQL で確認。
6. Test B または `demo-instance-b` に変え、別組み合わせの通知が確認できるか試す。
7. 1 時間を超える継続障害を評価する場合は、観測直前の 5 分に入るよう、
   5 分未満の間隔で検証リクエストを継続し、次の通知時刻を確認。
8. プラットフォームの遅延やルールの状態により厳密なメール最大件数は保証できません。
   他の次元まで抑止される等、意図と異なる場合は本番へ進めず、ルール分割や通知設計を再評価。
9. 検証後は故障注入を停止し、必要なら検証アラートルールを無効化。

## 12. よくあるトラブル

| 症状                                | 確認箇所                                                                                            |
| ----------------------------------- | --------------------------------------------------------------------------------------------------- |
| Function が一覧に出ない / 404       | 正しい .NET 10 isolated 設定か、publish の中身を発行したか、worker 起動ログ、ルート `/api/search` |
| APIM が 401/403                     | APIM subscription の状態/製品関連、Function Key、キーの二重指定、ネットワーク                       |
| 500 GATEWAY_CONFIGURATION_ERROR     | モードの綴り、両リストが空でないか、ドメインに scheme や wildcard がないか                          |
| mixed が 3 件のまま                 | monitor/off でないか、ガードなし API を呼んでいないか、設定の伝播、operation policy                 |
| good が blocked                     | キーワード/ドメイン値、Function の MOCK_*、deepLinks、ドメイン方式への変更履歴                      |
| Product が unassigned               | API/all-APIs キーではなく製品スコープの Test A/B を使用                                             |
| ログがない                          | API 診断ロガー、verbosity、Insights スコープ、取り込み遅延、日次上限、ネットワーク                  |
| 指標がない                          | With dimensions、診断 metrics=true、対象 API スコープ、メトリック名前空間                           |
| メールがない                        | KQL の結果、評価期間、アラート状態/抑止中、アクショングループのテスト、メールフィルター             |
| 非 JSON / Bing エラーが置換されない | PDF どおり対象外。BingGuardSkipped の理由を確認                                                     |
| policy 保存時エラー                 | Named Value の定義、禁止文字、fragment 名、APIM の許可型/式、エディターの詳細エラー                 |

APIM Test UI の trace は権限付きの診断機能を使用します。
旧 `Ocp-Apim-Trace` ヘッダーを追加する方式には依存しません。
Trace や検索語は機密情報を含み得るため、共有前に必ずマスキングしてください。

## 13. 本番移行・切り戻し

1. 正式な例外 2 ドメイン、英語文言、案内 URL、通知先、保持期間、検索語記録の可否を承認。
2. 既存 API の policy / Named Values / 診断 / キャッシュ構成をバックアップ。
3. 既存 Bing API の **非 current リビジョン**を作成。キー・製品・ネットワークを変更しません。
4. Named Values と fragments を追加。既存処理へ次の **include 2 行だけ**を組み込みます。
   モック用 [policy.xml](../apim/policy.xml) のルーティング/Function Key 部分は移植しません。

   ```xml
   <policies>
     <inbound>
       <base />
       <!-- 既存の Bing 認証・ルーティング等を維持 -->
       <include-fragment fragment-id="bing-guard-inbound" />
     </inbound>
     <backend><base /></backend>
     <outbound>
       <base />
       <include-fragment fragment-id="bing-guard-outbound" />
     </outbound>
     <on-error><base /></on-error>
   </policies>
   ```
5. この例で既存 policy 全体を置換しないでください。既存の各 section を保持して include を挿入します。
6. guard は最終応答を書き換える policy の **後**、`cache-store` の **前**に配置。
   親の outbound に cache-store がある場合、`<base />` の直後では既に保存済みです。
   親のキャッシュを無効化/再配置するなど、実際の継承順を調整します。
7. `Cache-Control=no-store` だけでは APIM `cache-store` の抑止になりません。
   検知した応答（monitor も含む）を保存しない条件分岐に変更します。
   inbound の cache-lookup/return-response がガードを迂回しないことも確認し、検証時はキャッシュを無効にします。
8. operation policy の早期応答、圧縮、Content-Length、既存 on-error も実 gateway で確認。
9. 非 current revision の URL で正常・異常・表示・ログ・通知を検証。
10. current へ昇格して **monitor** で開始。1〜2 週間の実ログで誤検知と実際のホストを確認。
11. 承認後 **enforce**。問題時は **bing-guard-mode=off** で guard を停止し、反映を確認。
12. 必要に応じ旧 revision を current に戻す。off は既に保存されたキャッシュを消さないため、
    誤ったキャッシュがあれば別途安全に無効化/失効させます。
13. 本番障害では時刻、実 Bing TraceId、customconfig、製品、APIM requestId を収集し、
    所定のサポート窓口へ連絡。モックの TraceId は送らないでください。

## 14. 検証記録・後片付け

この記録欄は UI 操作者向けのテンプレートです。
2026-11-10 に実施した自動デプロイ・実 APIM 24 ケース・ログ/アラートの結果は、
[実装仕様の Azure 検証結果](./implementation.ja.md#azure-実環境で確認済み2026-11-10)を参照してください。

| 確認項目                             | 実施日時 / 結果 / 証跡 |
| ------------------------------------ | ---------------------- |
| Function の発行（Cloud Shell / VS Code） | 未実施                 |
| 全件許可と元本文保持                 | 未実施                 |
| 混在/全件異常/deepLinks の単一置換   | 未実施                 |
| 0 件・非 200・非 JSON の透過         | 未実施                 |
| 英語固定・ランキング・各サイトの表示 | 未実施                 |
| monitor/off・設定のみの変更          | 未実施                 |
| Product A/B × instance-a/b のログ   | 未実施                 |
| 指標・アラート初回メール             | 未実施                 |
| 1 時間抑止と別次元の通知             | 未実施                 |
| キャッシュ・親/操作 policy・性能     | 未実施                 |
| 本番値の承認・切り戻し手順           | 未実施                 |

- 証跡にはキー/検索語の機密部分を含めません。
- 検証終了後は通知ルールと専用サブスクリプションを停止し、不要な資格情報を失効。
- 後日再利用しない場合、対象が検証専用 RG であることを確認してから Portal で削除。
  共有/本番 RG は削除しません。保持が必要なログは承認済みの方法で保管。

### 公式ドキュメント

- [.NET isolated worker](https://learn.microsoft.com/azure/azure-functions/dotnet-isolated-process-guide)
- [Cloud Shell の機能・認証・一時セッション](https://learn.microsoft.com/azure/cloud-shell/features)
- [Functions のパッケージ発行（Flex 対応）](https://learn.microsoft.com/azure/azure-functions/deployment-zip-push)
- [Azure CLI の config-zip コマンド](https://learn.microsoft.com/cli/azure/functionapp/deployment/source#az-functionapp-deployment-source-config-zip)
- [.NET SDK のユーザー領域インストール](https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script)
- [VS Code での Functions 開発・発行](https://learn.microsoft.com/azure/azure-functions/functions-develop-vs-code)
- [APIM と Application Insights](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights)
- [trace ポリシー](https://learn.microsoft.com/azure/api-management/trace-policy)
- [emit-metric ポリシー](https://learn.microsoft.com/azure/api-management/emit-metric-policy)
- [ログ検索アラートの作成](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
