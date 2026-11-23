# Backup and export

Settings → This app → **Backup and export** writes one zip with the app's
settings, its credentials, and the conversations of a window you choose.

The point is a file you can take *before* something goes wrong. Android's
"Clear storage" deletes everything the app holds — the servers, the keystore,
the Ubuntu with OpenCode and every conversation in it — and a reinstall does
the same. This archive is the copy that survives that.

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

There is no import yet. What the archive is good for today:

- Settings and credentials can be read and typed back in by hand.
- Conversations are readable JSON: the text, the tool calls (unless text only
  was chosen), the timestamps, the model and the cost of each message.
- A project folder can be rebuilt from the project export, which *is*
  restorable by unzipping it back into place.

An import that writes conversations back into the server's database is a
different problem — the database belongs to OpenCode, not to this app — and is
not promised by this feature.

## Where the code lives

- `lib/backup/app_backup.dart` — the window, the text-only trim, the file
  names, the manifest, and the writer. No platform calls; unit-tested.
- `lib/backup/backup_chat_reader.dart` — reads conversations from the
  connected server through the same gateway the chat screen uses, keeping the
  server's JSON.
- `lib/backup/backup_controller.dart` — one backup's states: read, stage, ask
  where, stream.
- `lib/backup/backup_wiring.dart` — preferences, the keystore, the server, the
  native export channel.
- `lib/ui/screens/settings/backup_screen.dart` — the page.
- `test/backup_export_test.dart` — the window rules, the trim, the names, the
  archive's contents, and a whole backup against a fake destination.

The zip itself is written by the native half of the project export
(`ProjectExportBridge.kt`, channel `oc/project_export`), which streams the
planned files into a document the person picked through the Storage Access
Framework. Nothing is left running when the page closes.
