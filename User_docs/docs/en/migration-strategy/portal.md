# Application migration

After moving an app externally, AppPorts retains a suitable local entry. The real app that occupies space and the entry you click may be in different locations.

## The real app and its local entry {#portal}

Ordinary apps use a lightweight **Stub Portal** by default. Clicking the local entry launches the real app on the external drive. It is neither another complete app nor a backup. Without the drive, the entry cannot substitute for the real app.

```mermaid
flowchart LR
  A[Click the local app entry] --> B[Locate the real app on external storage]
  B --> C[Launch the app]
  C --> D[Access app data at its existing location]
```

The last step explains why app and data migration are separate: messages and other data may stay local after the app moves.

## Entries for different kinds of content {#types}

| Content | How AppPorts handles it |
| --- | --- |
| Ordinary macOS app | A Stub Portal points to the real external app. |
| Eligible iPhone or iPad app | A launch entry suited to its wrapper structure; system and app restrictions still apply. |
| Folder or suite containing multiple apps | A Folder Mirror provides app entries and links to other managed content. |
| Manually selected traditional link migration | Use “Migrate Using Traditional Link” in the context menu. The whole app is external and a symbolic link remains locally. This manual option remains available; compatibility depends on the app. |
| Historical migration | The old entry is recognized and appropriate restoration or unlink actions are provided. |

Whole-app links and Contents-based entries can still appear in existing migrations. Recognizing them does not mean they are the default for new moves. Dependencies on particular directory structures or internal paths may also affect compatibility.

## Why update protection exists {#updates}

Some self-updaters replace or delete the app they are updating. AppPorts provides locked migration where protection is needed to reduce unintended changes to the external copy during updates.

A lock can also prevent self-updating. If an update fails, follow AppPorts' instructions, or move the app back locally, update it and move it out again. Do not repeatedly delete unfamiliar files by hand.

Sparkle and Electron identify frameworks or updater clues. Neither label alone means an app must be locked or cannot update. See [updates after migration](/docs/core#updates).

## What this means in practice {#limits}

A local entry preserves familiar launching where possible, but does not remove the external-drive dependency or guarantee that plugins, system permissions and self-updates are unaffected. Launch the app the way you normally do and verify its everyday features after migration.

Related: [local entries and real apps](/docs/glossary#local-portal), [badges](/docs/badges), and [data migration](/docs/datamigrae/baseinfo).

Earlier Contents, whole-app link and launcher implementations are preserved in [historical application migration methods](/docs/archive/app-strategies).
