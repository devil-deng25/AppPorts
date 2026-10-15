# Quick start

You need a Mac running macOS 12 or later and a reliably connected external drive with enough free space. This page covers installation and your first application migration. To move messages, caches, models or other data instead, complete preparation and continue to [Move data](/docs/datamigrae/operation).

## Download and install {#install}

1. Download AppPorts from the [download page](https://file.shimoko.com/AppPorts) or [GitHub Releases](https://github.com/wzh4869/AppPorts/releases).
2. Open the installer and drag AppPorts into your Mac's Applications folder.
3. Open AppPorts from Applications and follow the first-run guide. Do not keep running it from the installer image.

## Prepare permissions and storage {#permissions}

1. Connect the external drive and select an external storage location in AppPorts.
2. Follow the prompts to enable Full Disk Access for AppPorts in Privacy & Security. Grant App Management access if macOS requests it.
3. Reopen AppPorts when prompted. You can then run Check under Settings → Readiness.

**Only mount migration of container data requires unencrypted APFS storage.** Ordinary apps and folders have their own checks. You do not need to erase an existing disk for your first application migration. If its format is unsuitable, read [storage preparation](/docs/storage-guide#apfs).

## Complete your first move {#first-move}

1. Choose an app you know, save your work and quit it completely.
2. Select it under Local Apps and choose Move to External.
3. Read the destination and conflict messages, then confirm the content you intend to move.
4. Wait for copying, verification and cleanup to finish. Keep the drive connected and do not reopen the app during the operation.
5. Open the moved app from Finder or the Dock and check its main features.

The real app now lives on the external drive and a launch entry remains locally. The list shows the relevant [status badges](/docs/badges). If a destination already exists, permissions are missing or the operation stops, follow the prompt rather than deleting either copy yourself.

## Next steps {#next}

- App opens normally: learn about [updates after migration](/docs/core#updates).
- Want to move its data: read [Move data](/docs/datamigrae/operation).
- Want local storage again: read [restoration and reconnection](/docs/restore).
- Operation incomplete or app will not open: find the symptom in [troubleshooting](/docs/faq).

Migration changes where content is stored; it does not replace a backup. Connect the drive before using moved content. Before disconnecting it, quit apps using it and eject it normally.
