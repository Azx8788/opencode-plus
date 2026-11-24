# Backup and restore

Settings → This app → **Backup and restore** writes one zip with the app's
settings, its credentials, and the conversations of a window you choose — and
reads one back.

The point is a file you can take *before* something goes wrong. Android's
"Clear storage" deletes everything the app holds — the servers, the keystore,
the Ubuntu with OpenCode and every conversation in it — and a reinstall does
the same. This archive is the copy that survives that, and the import is what
makes it worth taking.

## What is in the zip

| Path | What it is |
| --- | --- |
| `manifest.json` | Format version, when it was taken, the app version, the selection, and how many settings, credentials, conversations and messages it holds |
| `config/settings.json` | Every stored setting, as stored — keys, values, and nothing re-typed into a schema |
| `config/secrets.json` | Every credential the app keeps in Android secure storage: Telegram bot token, provider keys, saved server passwords. **Plain text** |
| `chat/<date>-<title>-<id>.json` | One conversation per file: the server's own message JSON, oldest first |
| `README.txt` | The same description, inside the archive, for whoever opens it in a year |

The file is named `opencode-plus-backup-<date>-<window>[-private].zip`, so two
backups of the same day cannot be confused, and `-private` says the archive
holds credentials before it is opened.

## The window

Conversation history is the part that grows without bound, so it is the part
you bound: **7 days, 30 days, 90 days, or everything**.

- A conversation is included when it had activity inside the window, even if
  it started long before. The whole conversation is written, not just the
  recent messages: a transcript that starts mid-sentence is not a record.
- A conversation with no timestamp at all is kept. Dropping it would lose
  something nobody can get back; keeping it costs a file.
- At most 500 conversations are read in one pass. The window normally puts
  the useful set far below that.

**Text only** drops tool calls, their output, attachments and snapshots from
each message, keeping the words in order. On agent-heavy sessions that is
roughly an order of magnitude smaller — and no longer a complete record, so
it is off by default.

## Size

For orientation, a month of ordinary chatting is a few megabytes. What makes
an archive large is not the number of conversations but what agents did in
them: file contents read into context, command output, patches. If a backup
comes out far bigger than expected, text only is the switch that changes it.

Attachments and images referenced by messages are **not** included. They live
in the project folders, which the separate *Export projects* action in
This phone already covers.

## Privacy

`config/secrets.json` is plain text. Anyone who opens the archive can use the
Telegram bot token and the provider keys in it. Keep the zip where you would
keep a password — a computer, an encrypted drive, a mail to yourself — and do
not pass it through a chat app.

Leaving **Credentials** off produces a usable archive of settings and
conversations with nothing secret in it; the README inside then says the
credentials were left out.

## Restoring

**Choose a backup file** opens the system picker. The archive is unpacked into
the app's cache, read, and shown — taken when, by which version, how much of
it there is — *before* anything is written. Each part can be left out:

| Part | Where it goes back |
| --- | --- |
| Settings | `SharedPreferences`, key by key, as stored |
| Credentials | Android secure storage |
| Conversations | A read-only shelf inside this app |

Rules that matter:

- **A value in the archive wins; a key it does not mention is left alone.** A
  setting added after the backup was taken keeps its current value instead of
  being reset to a default.
- **Nothing is deleted.** Import is a merge, not a replacement.
- **Restart the app afterwards.** Settings and the Telegram relay are read
  when the app starts, so the running process keeps the old values until then.
- **The unpacked copy is deleted** when the page closes or the restore ends.
  It holds the credentials in plain text; leaving it in the cache would keep a
  second copy of them on the phone.
- A file that is not a backup is refused by name: not a backup, a different
  kind of zip, made by a newer app, damaged, or empty.

### Conversations are restored, not re-created

The conversations go onto a shelf this app owns — *Restored conversations*,
under the same settings page — where they can be read and copied from, one
conversation at a time.

They are **not** written back into OpenCode's own store. That store belongs to
OpenCode, its schema is versioned by OpenCode, and a write that is slightly
wrong breaks the server rather than the archive. They also cannot be continued
from the chat screen: they are a record, not a session.

Importing the same archive twice replaces its copy on the shelf instead of
piling up a second one, because the folder is named after the moment the
backup was taken.

## Where the code lives

- `lib/backup/app_backup.dart` — the window, the text-only trim, the file
  names, the manifest, and the writer. No platform calls; unit-tested.
- `lib/backup/app_restore.dart` — reading an unpacked archive back: the format
  checks, the merge rules, the shelf, and what a message said. No platform
  calls; unit-tested.
- `lib/backup/backup_chat_reader.dart` — reads conversations from the
  connected server through the same gateway the chat screen uses, keeping the
  server's JSON.
- `lib/backup/backup_controller.dart` — one backup's states: read, stage, ask
  where, stream.
- `lib/backup/backup_restore_controller.dart` — one restore's states: choose,
  unpack, inspect, apply.
- `lib/backup/backup_wiring.dart` — preferences, the keystore, the server, the
  native channel, the shelf's folder.
- `lib/ui/screens/settings/backup_screen.dart` — the page.
- `lib/ui/screens/settings/restored_chats_screen.dart` — the shelf's viewer.
- `test/backup_export_test.dart`, `test/backup_restore_test.dart` — the rules,
  the merge, the shelf, and a whole archive read back.
- `test/backup_page_widget_test.dart`, `test/backup_restore_flow_test.dart` —
  the page in both languages, and both halves against fakes.

The zip itself is written and unpacked by the native half
(`ProjectExportBridge.kt`, channel `oc/project_export`), which streams the
planned files into a document the person picked through the Storage Access
Framework, and unpacks the chosen one into the cache. Nothing is left running
when the page closes.
