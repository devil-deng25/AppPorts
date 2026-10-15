# Move data

Data migration moves application data, tool directories or your own folders. It is independent of moving the app itself: eligible data can move while the app stays local.

## Find the content to move {#choose}

| Content | Where to start |
| --- | --- |
| Messages, caches and other app-related data | Data Directories → App Data; select an app and expand its directories. |
| Package-manager caches, models and tool data | Data Directories → Tool Directories; inspect detected items. |
| Your projects, media or other folders | Directory Migration; use + in the local folder area and choose the source and external destination. |

App Data hides locked structures that are currently ineligible by default. Enable Show locked directory structure to inspect the full hierarchy and reasons. Items needing recovery or attention remain visible; another switch controls empty directories. **An available migration action does not guarantee execution checks will pass.** Space, permissions, processes using data and parent/child relationships with existing migrations still need checking.

Click status totals such as Linked, Mount Migration or Existing Symlink to show matching items. Necessary parent paths remain visible. Selecting a total does not shrink the other status totals, but other search and filter conditions still affect them. Click again or clear the filter to return; changing app or tab also resets this selection.

A User folder shortcut to Desktop, Downloads or Pictures is not data owned exclusively by the app. Its target size is not counted, and migration and restore are unavailable. Size on this volume and Target size identify measurement scope. Parent and child rows cannot simply be added, and displayed size is not guaranteed freed space.

## Prepare before migration {#prepare}

1. Back up important data, connect the destination drive and check space.
2. Save work and quit apps, tools and background jobs using the data completely.
3. Check permissions under Settings → Readiness. Run AppPorts from Applications.
4. Check directory name and location rather than guessing ownership from size.

If a related app is running, AppPorts may offer Quit app and continue to request a normal quit. If the app still needs a save or exit confirmation, handle that prompt, then return to AppPorts and choose Continue.

## Ordinary directories {#linked}

For an ordinary directory offering Migrate, click it, check the destination and confirm. AppPorts copies and verifies data, then creates a [symbolic link](/docs/glossary#symlink) at the original location. The resulting state is normally Linked.

Examples include npm and Gradle caches and some model or editor data. Quit the tool's jobs too; do not move directories while downloads, builds or writes are running.

A custom folder must be a real directory inside your home, not the entire home folder, and must not overlap managed directories. Check the destination shown when adding it before migration.

## Mount migration for container data {#mount}

In default mode, eligible container data uses the Migrate button and follows mount migration after checks. In classic mode, the separate action is Mount Migration. It needs **unencrypted APFS external storage**, enough space and correct permissions.

1. Choose Migrate in default mode, or Mount Migration in classic mode, and read the storage and permission checks.
2. If requirements are unmet, choose another location or keep the data local. You do not have to erase an existing disk to continue.
3. Confirm the data and destination. After completion, its state should be Mounted.
4. Open the original app. If macOS requests Removable Volumes access, authorize according to your preference.
5. Check existing content and perform a normal save.

Mount migration does not replace the app's signature. System authorization and compatibility still apply. If original data is not visible, stop further writes and follow [missing-data checks](/docs/faq#missing-data).

## Read migration progress {#progress}

The window explains whether it is preparing, scanning, copying, writing to disk, verifying, switching entries or cleaning old copies. **The percentage measures file copying only. At 100%, verification and cleanup may still remain.** Scanning and verification show processed items, bytes read or the current file to indicate actual work.

When no new progress arrives for a while, the window shows time since the last activity. Interpret that together with the current stage; do not disconnect the drive or force quit merely because the copy percentage has paused.

## After completion and when things go wrong {#after}

Connect the drive and confirm reconnection before opening the app. For Pending Mount, follow the mount prompt. External drive not connected does not mean data was deleted. See [data states](/docs/badges#data) for other labels.

Read [restoration and reconnection](/docs/restore) to return data locally or rebuild an entry. After interruption, or when only cleanup remains, preserve the copies AppPorts identifies and do not repeatedly start new migrations.

Related: [two data migration methods](/docs/datamigrae/baseinfo), [external storage](/docs/storage-guide#apfs) and [classic mode](/docs/classic-mode).

For the reasons behind protected directories and parent/child limits, read [data migration boundaries](/docs/blog/data-migration-boundaries).
