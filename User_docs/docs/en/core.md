# Move applications

Application migration moves the app itself. Messages, projects, models and caches may remain on the Mac and need separate [data migration](/docs/datamigrae/operation).

## Before moving {#prepare}

Connect the drive, select the external application library and check free space. Save your work and quit the app completely; back up important content first. System apps and protected locations are not suitable for direct moves. Follow the restrictions AppPorts shows.

## Move to an external drive {#move}

1. Select the app under Local Apps. Hold Command to select several apps.
2. Choose Move to External and check the destination.
3. If a same-named destination or version choice appears, compare both sides. Do not delete an uncertain copy as though it were junk.
4. Wait for copying, verification and creation of the local entry.
5. Launch the app from Finder or the Dock and test everyday actions such as opening files.

The external library contains the real app; a [launch entry](/docs/glossary#local-portal) remains locally. Verification or cleanup may still be running near the end of the progress display. Wait for the final result.

If the app is outside the default scan locations, use + beside Local Apps to add a scan directory, such as an installation folder managed by another tool.

## Updates after migration {#updates}

Update behavior differs by app. First check for Locked Migration or a related update notice.

| Situation | Suggested action |
| --- | --- |
| Protection prevents an update | Quit the app and follow AppPorts' instructions. If unsure, move it back locally, update it, then move it out again. |
| The updater installs the new version locally | Refresh the list. When Pending Migration appears, verify the version and move out the new local app. |
| App Store manages the external installation | On macOS 15.1 and later, use App Store external-install settings where supported. System and app requirements still apply. |
| App Store app on an older system | Check whether migration is enabled in settings. An update may require moving the new local version out again. |

On macOS 15.1 and later, App Store settings offer downloading and installing large apps to a separate disk. You can select the same external drive. This is a system installation feature; its conditions are determined by the App Store.

[Update protection](/docs/migration-strategy/portal#updates) addresses particular updater behavior. It does not mean every updater works the same way.

## Move back or repair an entry {#restore-links}

- Move the real app onto the internal drive: use Move Back to Local.
- App still exists externally but has no local entry: use Link Back to Local.
- Remove only the local entry: use its trash button, labeled “Disconnect this link and delete files”.

See [Restore, reconnect and unlink](/docs/restore) for the distinctions and steps. If an app will not open, check the drive and [status messages](/docs/badges), then follow [troubleshooting](/docs/faq#launch).
