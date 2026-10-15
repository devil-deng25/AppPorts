---
outline: deep
---

# 貢獻者指南

感謝你關注 AppPorts！我們歡迎社群成員參與貢獻，無論是修復 Bug、改進文件，還是新增新功能。

## 開始之前 {#section-1}

1. 搜尋現有的 [Issues](https://github.com/wzh4869/AppPorts/issues)，確認沒有相關的重複議題。
2. Fork 專案並克隆到本地。
3. 基於 `develop` 分支建立功能分支（`feat/your-feature`）或修復分支（`fix/your-fix`）。

## 開發方式 {#section-2}

### 關於 Vibe Coding {#section-3}

AppPorts 專案接受使用 AI 輔助工具（如 Cursor、GitHub Copilot、Claude 等）進行 Vibe Coding 開發。AI 工具可以顯著提高開發效率，**但提交程式碼的質量和正確性仍由貢獻者本人負責**。

使用 Vibe Coding 時請注意：

- **AI 助手必須遵循專案根目錄的 `CLAUDE.md`**。該檔案定義了編碼準則、架構規範、構建命令和開發流程。如 AI 助手未自動讀取該檔案，請在提示詞中明確要求模型先閱讀 `CLAUDE.md`。
- 建議透過多個 AI 模型交叉驗證生成程式碼的質量與安全性，避免單一模型的盲區。
- AI 生成的程式碼可能不符合專案既有風格，提交前請進行人工審查。
- AI 無法替代對 macOS 系統行為的理解。涉及檔案系統操作、程式碼簽章、權限管理等邏輯時，請務必手動驗證。
- **核心功能**（如遷移策略、資料目錄遷移、程式碼簽章等）的變更必須先提交 Issue 討論，獲得確認後再執行開發。

### 程式碼規範 {#section-4}

- 遵循 Swift 程式碼規範和專案既有風格。
- 為複雜邏輯編寫清晰的 Swift 文件註釋。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字串使用 `.localized`。

## 測試要求 {#section-5}

::: warning 所有 PR 必須通過測試
無論使用何種開發方式，提交 PR 前必須完成以下測試。CI 會自動執行編譯煙霧檢查，未通過的 PR 將被阻止合併。
:::

### 必須通過：編譯煙霧檢查 {#section-6}

所有 PR 必須通過 Xcode Release 編譯，這是合併的硬性門檻：

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 按需執行：專項測試 {#section-7}

當 PR 涉及對應模組時，建議主動補跑以下專項測試。CI 也會在 PR 中以 Advisory 模式執行，結果不阻塞合併，但會提供反饋。

#### 資料目錄測試 {#section-8}

當 PR 涉及 `DataDirMover`、`DataDirScanner` 或資料目錄遷移相關邏輯時執行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 應用遷移測試 {#section-9}

當 PR 涉及 `AppMigrationService`、`AppScanner` 或應用遷移邏輯時執行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 日誌測試 {#section-10}

當 PR 涉及 `AppLogger` 或診斷功能時執行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### 本地化審計 {#section-11}

當 PR 涉及使用者可見文案、選單、彈窗、設定項、錯誤提示時執行：

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### 測試總覽 {#section-12}

| 測試套件 | 涉及模組 | 執行時機 |
|----------|----------|----------|
| 編譯煙霧檢查 | 全專案 | **必須**（CI 強制） |
| `DataDirMoverTests` | 資料目錄遷移 | 涉及 `DataDirMover` 時 |
| `DataDirScannerTests` | 資料目錄掃描 | 涉及 `DataDirScanner` 時 |
| `AppMigrationServiceTests` | 應用遷移 | 涉及 `AppMigrationService` 時 |
| `AppScannerTests` | 應用掃描 | 涉及 `AppScanner` 時 |
| `AppLoggerTests` | 日誌與診斷 | 涉及 `AppLogger` 時 |
| `LocalizationAuditTests` | 本地化 | 涉及使用者可見文案時 |

## 本地化 {#section-13}

- 本地化適配是推薦項，不作為外部貢獻者提交 PR 的強制門檻。
- 如 PR 新增、修改或刪除了使用者可見文案，歡迎在同一個 PR 中同步更新 `Localizable.xcstrings`。
- 如本次暫不處理，請在 PR 說明中簡要說明原因或後續計劃。
- SwiftUI 字面量使用 `LocalizedStringKey` API；AppKit/API 字串使用 `.localized`。
- 動態文案建議使用格式化 key，如 `String(format: "排序：%@".localized, value)`。
- 語言列表統一維護在 `AppLanguageCatalog`，不要在多個頁面重複硬編碼。
- 如 PR 變更了選單、彈窗、設定項、日誌匯出、錯誤提示、狀態文案或 onboarding 文案，建議至少檢查一次 `zh-Hans` 和 `en` 的實際顯示結果。

更多規則見：[LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit 規範 {#section-14}

- **Issue 優先**：重要功能的變更請先透過 Issue 討論
- **保持原子化**：每個 PR 儘量只解決一個問題或新增一個功能
- **Commit 資訊建議**：
  - `feat: ...` — 新功能
  - `fix: ...` — 修復 Bug
  - `docs: ...` — 文件更新
  - `refactor: ...` — 重構
  - `test: ...` — 測試相關

## 提交 PR {#section-15}

1. 確保分支基於最新的 `develop` 分支。
2. 推送到你的 Fork 倉庫。
3. 向 AppPorts 的 `develop` 分支提交 Pull Request。
4. 填寫 PR 模板中的必填項。
5. 等待 CI 檢查通過和 Code Review。

::: tip 提高合併效率
- 保持每個 PR 聚焦於單一問題或功能。
- 如實填寫 PR 模板中的測試情況。
- 涉及 UI 變更時附上截圖。
:::

## 歡迎的貢獻方向 {#section-16}

- 針對 `AppScanner` 等核心邏輯的穩定性和效能改進。
- UI/UX 最佳化，特別是符合 macOS 系統原生體驗的改進。
- 中英文件的同步和完善。
