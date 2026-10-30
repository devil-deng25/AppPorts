# Restore, reconnect and unlink

Decide whether you want to change the **storage location** or the **access entry**. Connect the original external drive, save your work and quit related apps. Restoring locally also requires enough internal space.

## Choose the right action {#choose}

| Goal | Action | Where content ends up |
| --- | --- | --- |
| Move an app from the external drive back to the Mac | Move Back to Local | The real app is local. |
| Return moved data to its original directory | Restore | Data returns to the original local location. |
| App is external but its launch entry is missing | Link Back to Local | The real app stays external. |
| Data is external but its local link is missing | Relink | Data stays external; a local entry is rebuilt. |
| A data volume is online but not attached at the original directory | Mount | Data stays external; access at the original path is restored. |
| Remove only an app's local entry | Trash button in the local list | The real external app is retained. |

## Move an app back locally {#apps}

1. Select it in the external library and choose Move Back to Local.
2. Check the local destination. If a real app with the same name or another conflict exists, follow the prompt rather than overwriting it yourself.
3. Wait for copying, verification and cleanup.
4. Open the app from Finder or the Dock and check that it uses the local copy.

Moving the app back does not automatically restore separately managed data. Continue below if that data must return too.

## Restore data to its original location {#data}

1. Find the managed item under Data Directories or Directory Migration and choose Restore.
2. Confirm that the related app is closed, the original drive is online and local space is sufficient.
3. Wait for AppPorts to copy data back and switch the entry.
4. Open the app, check existing content and saving, and confirm the final state.

AppPorts then handles external copies or dedicated volumes that can safely be cleaned up. If retained content or unfinished cleanup is reported, keep it and follow the prompt. An app opening successfully does not prove all cleanup is finished.

## Restore only the entry {#reconnect}

For an Unlinked app or an external copy without an entry, use Link Back to Local. For data marked Awaiting Relink, check the external destination and use Relink. A container volume marked Pending Mount uses Mount.

These actions do not move data back internally. If new content has appeared at the original local location, establish what each copy contains before proceeding; do not force reconnection by overwriting it.

## Unlink an application {#unlink}

In the local app list, click the linked app's trash button. Its tooltip is “Disconnect this link and delete files”; an orphaned link also offers Delete Orphaned Link in its context menu. This removes the local entry managed by AppPorts while retaining the real external app. **It does not restore a data directory.** You can use Link Back to Local again later.

Before removing AppPorts, restore container data it still manages. Otherwise the automatic mount task may lose the program it needs. See [troubleshooting](/docs/faq) for interruption, offline drives and conflicts.

## Resolve unfinished work and retained copies {#recovery}

Open a task needing attention in Task Center and choose Resolve Issues. Read the current migration records first. Quit the associated app and connect and unlock the original drive. Use Check Permissions if needed, then retry. Check the items shown in the panel: retrying pending operations can affect several records.

| Choice in the data recovery panel | Effect |
| --- | --- |
| Retry / Try Cleanup Again | Recheck and continue the relevant operation; differing old files are not forcibly deleted. |
| Decide Later | Pause automatic handling and keep files; you can retry explicitly later. |
| Open Old Copy | Inspect retained content after data has switched and its location is verified. |
| Keep Copy and End Cleanup | Available only after data has switched. Stop automatic cleanup and warnings; the old copy still occupies space and can be opened or retried individually later. |

A task can still need attention when migration has finished but old-copy cleanup has not. Background cleanup of an old attempt does not prove the original migration succeeded. Check the actual directory state as well. Removing task history does not resolve these records.

The app recovery panel also offers Retry Processing, Ignore Errors and End Task, and Ignore Errors and Move Back. Prefer normal retry. Ignore Errors and End Task archives the original record as incomplete and keeps files. **Ignore Errors and Move Back skips content verification.** After a successful copy, it replaces the local entry, keeps the external original and any existing local copy, and archives the original record as incomplete. Use it only if you understand the confirmation and will check the result yourself; it is not a verified successful restore.
