# Contributor guide

Thank you for your interest in AppPorts. Contributions are welcome, whether fixing bugs, improving documentation, or adding features.

## Before you start {#section-1}

1. Search existing [Issues](https://github.com/wzh4869/AppPorts/issues) for duplicates.
2. Fork and clone the project.
3. Create a feature (`feat/your-feature`) or fix (`fix/your-fix`) branch from `develop`.

## Development approach {#section-2}

### Vibe coding {#section-3}

AppPorts accepts AI-assisted development with tools such as Cursor, GitHub Copilot, and Claude. These tools can improve productivity, but **the contributor remains responsible for code quality and correctness**.

- **AI assistants must follow the root `CLAUDE.md`**, which defines coding, architecture, build commands, and workflow. Explicitly ask the assistant to read it first if it does not do so automatically.
- Cross-check generated code with multiple models where possible to reduce blind spots.
- Review generated code yourself for consistency with the project style.
- AI does not replace understanding macOS behavior. Manually validate filesystem, signing, and permission logic.
- **Core-feature changes**, including migration strategies, data migration, and signing, require an Issue discussion and confirmation before development.

### Code style {#section-4}

- Follow Swift conventions and the existing project style.
- Write clear Swift documentation comments for complex logic.
- Use `LocalizedStringKey` APIs for SwiftUI literals and `.localized` for AppKit/API strings.

## Testing requirements {#section-5}

::: warning All PRs must pass testing
Complete the required checks before submitting a PR, regardless of development method. CI runs a compilation smoke check and blocks merging when it fails.
:::

### Required: compilation smoke check {#section-6}

Every PR must pass a Release build in Xcode. This is a hard merge requirement:

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

### As applicable: focused tests {#section-7}

Run the relevant focused tests when a PR changes these modules. CI also runs them in advisory mode: they provide feedback without blocking merges.

#### Data-directory tests {#section-8}

For `DataDirMover`, `DataDirScanner`, or related migration logic:

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

#### App-migration tests {#section-9}

For `AppMigrationService`, `AppScanner`, or app-migration logic:

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

#### Logging tests {#section-10}

For `AppLogger` or diagnostics:

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

#### Localization audit {#section-11}

For user-visible text, menus, dialogs, settings, and errors:

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

### Test overview {#section-12}

| Suite | Area | When to run |
| --- | --- | --- |
| Compilation smoke check | Entire project | **Required** by CI |
| `DataDirMoverTests` | Data migration | Changes to `DataDirMover` |
| `DataDirScannerTests` | Data scanning | Changes to `DataDirScanner` |
| `AppMigrationServiceTests` | App migration | Changes to `AppMigrationService` |
| `AppScannerTests` | App scanning | Changes to `AppScanner` |
| `AppLoggerTests` | Logs and diagnostics | Changes to `AppLogger` |
| `LocalizationAuditTests` | Localization | User-visible text changes |

## Localization {#section-13}

- Localization is recommended, but not a mandatory entry requirement for external contributors' PRs.
- When adding, changing, or deleting user-visible text, update `Localizable.xcstrings` in the same PR where possible.
- If deferred, briefly state the reason or follow-up plan in the PR.
- Use `LocalizedStringKey` APIs for SwiftUI literals and `.localized` for AppKit/API strings.
- Prefer format keys for dynamic text, such as `String(format: "排序：%@".localized, value)`.
- Keep the language list in `AppLanguageCatalog`; do not hardcode duplicate lists across views.
- For menu, dialog, settings, log-export, error, status, or onboarding changes, inspect actual `zh-Hans` and `en` display at least once.

See [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md).

## Commit conventions {#section-14}

- Discuss significant feature changes in an Issue first.
- Keep each PR focused on one problem or feature.
- Recommended commit prefixes: `feat:` for features, `fix:` for bugs, `docs:` for documentation, `refactor:` for restructuring, and `test:` for testing.

## Submit a PR {#section-15}

1. Base your branch on the latest `develop`.
2. Push to your fork.
3. Open a Pull Request targeting AppPorts' `develop` branch.
4. Complete required fields in the PR template.
5. Wait for CI and code review.

::: tip Help review move smoothly
- Keep each PR focused on one issue or feature.
- Report testing accurately in the template.
- Include screenshots for UI changes.
:::

## Welcome contribution areas {#section-16}

- Stability and performance of core logic such as `AppScanner`.
- UI/UX improvements, especially native macOS behavior.
- Keeping Chinese and English documentation complete and synchronized.
