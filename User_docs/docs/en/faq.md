# Questions and troubleshooting

Save your work and note the state and error AppPorts displays. For missing data or interrupted migration, preserve the original drive and existing copies before following the relevant checks.

## App will not open or quits immediately {#launch}

Check that the original drive is online and the local entry is not an Orphaned Link. For Signature replaced, or a problem that began after upgrading to macOS 27, follow [upgrades and repair](/docs/macos-27). Otherwise check whether the original app supports the OS and retain error details. Not every launch failure is caused by signing.

## App opens but existing data is missing {#missing-data}

Quit the app to avoid writing into a newly created empty directory. In AppPorts, check for Mounted or a working link, then check the original app's Removable Volumes permission. Files existing externally does not establish that the app is connected to them. If both locations contain new content, preserve both, report the path types and states, and do not overwrite either.

## External drive not connected or Orphaned Link {#offline}

Reconnect the original drive, check Finder or Disk Utility, unlock it if needed, and refresh AppPorts. If the volume is online but Pending Mount, choose Mount. These states may indicate temporary disconnection. If the original drive and destination are confirmed but the issue persists, [export diagnostics](/docs/faq#feedback).

## Mount migration checks fail {#mount}

Check permissions, connectivity, format and encryption under Readiness. Installation location and operation-specific space are checked when starting migration. Container mount migration currently requires unencrypted APFS; do not apply that requirement to all other content. Choose another destination or keep data local. See [storage preparation](/docs/storage-guide#apfs).

## After migrating, an app says the data directory is not mine {#owners}

Such messages come from the app's own background service — for example clash-verge's system service refusing to start the kernel (error 1012). The usual cause is not lost permissions but a target disk that does not record file ownership: exFAT and FAT32 have no ownership field, and HFS+ mounted with ownership ignored writes new files as a placeholder user. Your account sees itself; the administrator service sees that placeholder, so the two disagree.

The message often suggests `sudo chown`, but on such volumes the system silently drops the change — it looks successful while changing nothing. What works: restore this data locally, or move it to an APFS disk (APFS keeps the real owner); for HFS+ you can untick “Ignore ownership on this volume” in Finder's Show Info and migrate again. exFAT has no such switch. See [Does the external drive remember file owners?](/docs/storage-guide#owners).

## Destination exists, a copy is retained, or cleanup is incomplete {#conflict}

Identify the contents on both sides. Target Conflict needs an ownership check; Retained Copy or failed cleanup may mean the main operation succeeded but cleanup remains. Follow the retry or retain options. Do not repeat migration, manually delete recovery copies or overwrite same-named directories. See [restoration and reconnection](/docs/restore) for the distinction between repairing an entry and moving data back.

## Should I restart an interrupted migration? {#interrupted}

Keep the original storage connected and inspect AppPorts' recovery instructions. Interruption can occur during copying, switching or cleanup, with different valid copies remaining at each stage. Preserve the temporary directories and backups identified by the app. If uncertain, record the last step and error rather than choosing a copy to delete yourself.

## What is unsuitable for migration? {#compatibility}

System apps, protected container structures, the entire home folder and overlapping managed directories have additional restrictions. Virtual machines, databases and downloading game libraries may have background writers; stop their use completely first. Detecting a directory does not establish that its app supports arbitrary external storage. Prefer an app's own storage-location setting when appropriate.

## Why are some container directories protected? {#protected}

Some directories maintain system structure, such as the container root and specific temporary directories. Changing them can prevent launch even when copying and mounting succeed. Respect protection messages; see [container structure experiments](/docs/blog/data-migration-boundaries#starting-point) for the evidence.

## How do I update a moved app? {#updates}

Look for Locked Migration or Unlocked Migration. Protected apps may need to move back, update and move out again. App Store-managed external installations have their own process. Follow [application updates](/docs/core#updates), without deleting the external copy just to get an update through.

## Why does Disk Utility show extra AppPorts volumes? {#volumes}

They may be dedicated mount-migration data volumes. They may not remain visible in Finder's sidebar, but hold real data. To undo migration, use Restore in AppPorts rather than erasing or deleting the volumes in Disk Utility.

## Can I delete AppPorts Backups? {#signature-backups}

This folder holds official app originals saved before manual re-signing, not message or document backups. If you no longer need an original and no operation is pending, you may delete that package in Finder. The installed app and personal data remain, but restoring official status may then need an official installer. AppPorts also removes originals proven redundant; see [retention and cleanup](/docs/settings#signature-backup-cleanup).

If recovery cannot find an original, connect its drive and verify that the folder is still in place. New originals are external even when the app remains internal. Without suitable external storage, re-signing a new official original stops before changing the installed app.

## Before removing AppPorts {#uninstall}

Restore container data it still manages and confirm cleanup. Removing the program alone does not return data locally and may leave automatic reconnection without its executable. Check moved apps and ordinary data using the [restoration guide](/docs/restore) too, and establish where they are stored.

## Does AppPorts upload my files automatically? {#privacy}

Migration runs locally. Logs and diagnostic packages are also stored locally first. Update checks and sponsor-list loading use the network, so the app is not entirely offline. See the [privacy policy](/docs/privacy) for information and recipients.

## Report a problem {#feedback}

In [GitHub Issues](https://github.com/wzh4869/AppPorts/issues), describe AppPorts and macOS versions, drive format, the operation, the complete error message and reproducibility. Use Logs → Export Diagnostic Package to obtain records. Check for private paths or content before sharing. Packages are not uploaded automatically; do not publish messages, account details or unrelated files.
