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
