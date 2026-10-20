# Bee Companion

Bee Companion is a **native macOS application for one user**, combining everyday work tools with a readable, on-demand Shabbat display. The interface is SwiftUI and AppKit, not a website or an embedded browser. A local Docker Compose backend stores synchronized work and files; the Mac keeps its own SQLite database so everyday editing continues when Docker or the internet is unavailable.

**This is a single-user application, not a multi-user service.** A deployment has exactly one owner account, no public registration, and no collaboration or shared workspaces. Give another person a separate backend instance and configuration file. The same native app can connect to any compatible instance, one at a time.

## Features

### Today and work tools

- **Today:** a dashboard of tasks, upcoming reminders, three world clocks, the Hebrew calendar, zmanim, and followed instruments. Clocks and displayed timestamps omit seconds. The zmanim strip advances independently to the next upcoming time.
- **Tasks:** title, description, due date or date/time, To do/In progress/Done/Cancelled status, independent archive state, file attachments, linked reminders, TXT/RTF export, and sharing.
- **Files:** an app-owned folder hierarchy with upload/download, resumable transfers, checksums, immutable file versions, rename/move/duplicate, trash/restore, confirmed permanent deletion, offline copies, Quick Look, default-app opening, and detection of externally edited working copies. Moving a file preserves its attachments.
- **Notes:** Markdown source and preview or native RTF editing, title/description, autosave, full-text search, import/export, and attachments. Format conversion creates a copy to preserve the original.
- **Alarms:** complete-description popup windows while the app runs, local macOS notification fallback when closed, snooze, missed-occurrence recovery, and one-time/daily/weekday/weekly/monthly recurrence. Recurrence preserves wall-clock time across daylight-saving changes; monthly dates skip months without that day.
- **Agenda:** read selected Apple calendars alongside app tasks/reminders, with day/week/month ranges and calendar grids. Calendar access is explicitly granted through macOS, and Apple event data stays on the Mac. Editing external appointments remains in Apple Calendar.
- **Hebrew calendar:** Hebrew/Gregorian dates, Israel/diaspora selection, holidays, fasts, Rosh Chodesh, Torah portions, Omer, candle lighting/Havdalah, and daily zmanim through Foundation and Hebcal. Location-dependent times require coordinates and a time zone.
- **Stocks:** London Strategic Edge instrument search, watchlist, latest available minute candle close, change against the previous completed daily bar, timestamps, and editable TradingView symbol mappings. Prices are labeled candle data rather than live ticks.
- **Sharing:** the native share picker, plain-text WhatsApp compose flow, and LocalSend handoff for files. Destination applications must be installed or available. The user confirms recipients and sending; nothing is sent automatically.

### RSS reader

Configure **up to three RSS or Atom feeds** in **Settings → RSS & Shabbat mode**. Each has a name and public HTTP/HTTPS feed URL. Save the settings to queue them for backend synchronization. The reader groups articles by feed, displays publication dates and plain-text summaries, and opens original articles in the default browser. It does not crawl full articles or load remote scripts and images.

The backend downloads and parses feeds, limits download size, checks redirects, rejects private-network destinations, and disables XML entity expansion. Public feeds on standard HTTP/HTTPS ports are supported; authenticated feeds and private LAN feeds are not. Failed feeds retain saved articles and show their unavailable/stale state. Previously loaded articles are also cached on the Mac for offline reading.

### Shabbat mode

Press **⌘⇧S**, use the **View → Open Shabbat Mode** menu item, or click the moon-and-stars toolbar button. A separate native full-screen window shows all of the following on one page:

- Upcoming zmanim, with the next occurrence emphasized.
- Local weather, temperature, daily high/low, humidity, and wind.
- Up to six selected watchlist instruments.
- Up to three feed columns whose headlines and summaries rotate automatically.

The layout uses large type, a dark high-contrast background, and no seconds display. The display stays awake while the window is open. Once started, the screen updates without mouse input. **Esc** closes the Shabbat window and releases the display-awake assertion. Activation is on demand; there is no automatic Friday activation or scheduled shutdown.

In Settings, choose a refresh interval from one minute to one hour, a headline rotation interval from 10 to 120 seconds, and the stocks to display. These choices, feed URLs, and location preferences synchronize with the backend. Weather and zmanim use the configured city coordinates/time zone rather than requesting continuous location tracking. Feed, weather, and market caches have their own lifetimes, so a refresh check does not necessarily mean a new provider request every time. Feed cache is at most five minutes, weather ten minutes, and market candles one minute.

## Get started

### 1. Install prerequisites

You need:

- macOS 14 or later, on Apple Silicon or Intel.
- Xcode 15 or later with command-line tools for building the native app. Launch Xcode once to finish installing components and accepting its license.
- Docker Desktop with Docker Compose v2, running before backend setup.
- Python 3.11 or later for the administration scripts.
- Git and internet access to obtain dependencies and external data.
- A London Strategic Edge API key if you want stock search/prices. Other features can be set up without it.

Check the tools:

```sh
xcodebuild -version
swift --version
python3 --version
docker compose version
```

Clone the source:

```sh
git clone https://github.com/bee-raph/bee-companion.git
cd bee-companion
```

### 2. Initialize your private backend

Run:

```sh
scripts/companionctl init --name "My Bee Companion" --login owner --port 8787
```

The initializer creates `.runtime/` with restricted permissions, generates a database password and instance UUID, and prompts securely for your London Strategic Edge key and owner password. Enter an owner password of at least 12 characters and save it in your password manager. You can leave the provider key blank initially; stock endpoints will explain that it is missing. Keys and passwords do not appear in command arguments or client configuration.

The command builds the backend image, starts PostgreSQL, applies migrations, provisions the sole owner, and starts the API and worker. It is safe to rerun against the same instance: existing data and owner credentials are preserved. The API listens at `http://127.0.0.1:8787`; PostgreSQL is not exposed on a host port. No Supabase, cloud database, mail server, or browser frontend is required.

Verify readiness:

```sh
scripts/companionctl status
scripts/companionctl validate
```

The final command should report `{"status":"ready"}`. Keep Docker Desktop running whenever you want synchronization or fresh external data. Closing Docker does not erase your work or prevent local task/note editing.

### 3. Build and open the native application

For local use:

```sh
scripts/build-macos debug
open "macos/dist/Bee Companion.app"
```

The script resolves Swift dependencies, builds an actual `.app`, copies the native icon and resources, and signs it locally. It stages each new build separately and publishes it by renaming directories; it never overwrites a running executable. Previous builds are retained in `macos/dist/.previous-builds/`. Quit and reopen the app to use an updated build.

For a universal Intel/Apple Silicon app and DMG:

```sh
scripts/build-macos release
```

Local signing is suitable for your own build. A notarized distributable requires an Apple Developer ID and a configured notarytool Keychain profile:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build-macos release
```

The script explicitly skips notarization when those credentials are absent. Signing identities, certificates, and notary credentials must remain outside this repository.

### 4. Connect the app to your instance

Open **Settings → Import instance configuration** and choose:

```text
<your checkout>/.runtime/client.companion-instance.json
```

Because `.runtime` is hidden, press **⌘⇧G** in the file picker and paste its full path. Sign in with the owner login and password you chose during initialization. The app checks the instance UUID and API version, stores session tokens in macOS Keychain, and should display **Everything is up to date** after synchronization.

The generated configuration contains only an instance name, UUID, API URL, and protocol version. It contains no password, stock key, or administrative credential. Do not copy someone else's runtime directory. A newly initialized deployment does **not** generate an `initial-login.txt` file: use the password you supplied, or reset it locally as described below.

### 5. Configure calendars, location, feeds, and Shabbat mode

1. In **Agenda**, choose **Enable Apple Calendar** and grant full Calendar access. If access was denied, enable Bee Companion in **System Settings → Privacy & Security → Calendars**, then return and refresh. The calendar menu shows selection checkmarks, select/deselect-all actions, and explanations when no calendars are available.
2. In **Settings**, enter the city name, latitude, longitude, and IANA time zone, for example `Asia/Jerusalem`. Coordinates are entered manually and used for weather and Hebcal calculations. Choose Israel or diaspora observances.
3. Configure up to three comma-separated world-clock IANA zones.
4. Add instruments from **Stocks**. Verify each TradingView mapping if provider and exchange naming differ.
5. In **Settings → RSS & Shabbat mode**, add up to three actual RSS/Atom URLs, choose refresh/rotation intervals, and select up to six stocks. Click **Save reader & Shabbat settings**. These settings use the same offline queue and revision-checked sync as the rest of the app.
6. Open **RSS Reader** to load articles. Then press **⌘⇧S** to open Shabbat mode. Leave the app and Docker running for unattended updates. Press **Esc** to exit.

## London Strategic Edge requirement

Obtain your own key through [London Strategic Edge](https://londonstrategicedge.com/data). The backend uses the provider's [official Python SDK](https://github.com/londonstrategicedge/lse-data), pinned in `backend/requirements.txt`. The key is stored only in the private deployment folder and mounted into backend containers as a Compose secret. It is never shipped in the native client, passed through a public URL by the client, or included in this repository.

For an existing instance, edit `.runtime/lse_api_key` locally and restart the backend. Keep its permissions restricted. Do not paste the key into source, README examples, issue reports, or commits.

Search reads the provider catalog; quotes use minute candles and previous daily data, cached and request-budgeted on the backend. Availability, market coverage, delay, quotas, and permitted use depend on your provider account and current terms. Some catalog symbols appear in more than one dataset; search rows use dataset-and-symbol identities. This version's price adapter uses the standard candles endpoint and does not implement options-chain pricing. Use stock/ETF listings for the watchlist.

No brokerage connection or trade execution is included. Each independent user needs their own provider key and must comply with the provider's [data terms](https://londonstrategicedge.com/terms); do not run this deployment as a redistributed market-data service.

Weather uses [Open-Meteo](https://open-meteo.com/), with attribution on screen; review its service terms for your intended usage, particularly commercial deployments. Hebrew calendar data uses [Hebcal](https://www.hebcal.com/home/developer-apis). Neither integration needs a key for the configured public endpoints. RSS publishers control their own availability and content terms.

## How synchronization works

The Mac's GRDB/SQLite database is the interface's immediate source of truth. Saving an item commits its local record and outgoing mutation in one transaction. Draft mutations that have never been sent are coalesced; sent operations retain stable IDs so retries cannot create duplicates.

The client pushes revisions and pulls a durable server change cursor on launch, reconnect, manual sync, and periodically while active. The API applies expected-revision checks, stores idempotency receipts, and serializes change-log allocation with a PostgreSQL advisory lock. Pull pages and cursors are committed atomically on the client. If another client changed a record, the app keeps the local draft and server version for explicit resolution in Settings; it does not silently discard note or file edits. Deletion markers and history are retained, so cursors currently do not expire.

Tasks, notes, folders, file metadata, attachment links, reminders, occurrence actions, watchlist, and user preferences synchronize. RSS feed configuration, Shabbat refresh/rotation, selected stocks, city coordinates, and Hebrew calendar preferences are part of the synced preferences. Apple appointments, permission decisions, window layout, and local caches remain device-local.

Uploads persist their session and confirmed offset on both sides. Content is checksum-verified before becoming an immutable version. Downloads are checksum-checked. A working file modified by another application can be uploaded as a new version. Server file paths use generated identifiers rather than visible folder names.

## Administration, backup, and recovery

```sh
scripts/companionctl start
scripts/companionctl stop
scripts/companionctl status
scripts/companionctl validate
scripts/companionctl backup
scripts/companionctl backup --export-to /Volumes/YourDisk/BeeCompanionBackups
scripts/companionctl upgrade
scripts/companionctl reset-password
scripts/companionctl restore --archive /absolute/path/backup.tar.gz
```

Password reset is a local administrative action and revokes sessions. There is no email-based recovery service.

Docker named volumes hold PostgreSQL data, immutable files, and backups. `stop` preserves data. **Do not use `docker compose down -v` on an instance you need.** Docker Desktop's storage settings determine the host disk used for these volumes; the instance directory controls configuration and secret storage.

Backups include a PostgreSQL dump, referenced objects, instance/version manifest, and checksums. The worker schedules daily backups while running and retains seven recent and four weekly snapshots. Local backups are same-machine copies until exported to another disk. Export requires the API container to be running. Protect backup archives: they contain private work and owner password hashes.

Upgrade creates a backup, stops API/worker writes, builds and migrates, then verifies readiness. A failed migration leaves writes stopped for recovery. Restore also stops writes, validates objects, restores database and files, and revokes sessions. Restoring into another deployment uses that deployment's configured instance identity and the recovered owner/work data. Backup/restore has been rehearsed with an isolated second deployment.

### Another user or instance

```sh
scripts/companionctl --instance-dir .runtime-second init \
  --name "Second Companion" --login owner --port 8788
```

Every instance has its own Compose project, database, files, backups, secrets, UUID, and sole owner. Pass `--instance-dir` **before** the command for subsequent administration. Import that instance's generated configuration in the same native app. Switching instances requires pending work and conflicts to be resolved. Local databases, file caches, and Keychain sessions are namespaced by instance UUID.

## Development and tests

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt pytest
PYTHONPATH=backend .venv/bin/pytest backend/tests scripts/tests -q
swift test --package-path macos
```

The API schema is committed in `backend/openapi.json`. After API changes:

```sh
FILES_ROOT=/tmp/bee-companion-api PYTHONPATH=backend \
  .venv/bin/python scripts/export-openapi.py
```

CI runs backend/packaging tests, checks schema drift, and runs native tests. API documentation is available at `http://127.0.0.1:8787/docs`; private endpoints require authentication.

The backend uses FastAPI, SQLAlchemy/Alembic, PostgreSQL 17, private filesystem storage, and a PostgreSQL-backed worker. Revisioned work entities use a shared `records` envelope with validated kinds and string-valued payloads. Sessions, file versions, uploads, jobs, provider cache, mutation receipts, and change log have dedicated tables. Rich notes store base64 RTF plus extracted text in the note payload. The native stack is SwiftUI/AppKit, GRDB/FTS5, EventKit, UserNotifications, Keychain, and URLSession.

## Security and practical limits

- One owner, Argon2id password hashes, opaque hashed server tokens, rotating refresh credentials, Keychain client storage, and rate-limited login. There is no signup endpoint.
- The API binds to IPv4 loopback only; PostgreSQL is not published. The native client accepts HTTP only for loopback configurations. Remote hosting is not packaged here and would require HTTPS and an appropriate deployment/security setup.
- `.runtime*`, environment files, local databases, caches, signing keys/certificates, generated applications, installers, and secret directories are ignored. Never force-add them. A staged-file secret check is available as `python3 scripts/check_secrets.py --staged`.
- This app is not a continuously running alarm service. Closing the last main window quits it. macOS controls closed-app notifications; sleeping/powered-off Macs cannot guarantee on-time popup windows. The client schedules the earliest 60 occurrences within 30 days whenever opened.
- Cached files are retained rather than automatically evicted. Offline pinning records intent and downloads content; cache-size management is not implemented.
- Automated tests cover persistence/sync, calendar state, recurrence, alarm-window ownership, result identities, RSS parsing/limits/private-address protection, preferences, and safe packaging. Actual Calendar permission prompts, notification delivery, third-party share apps, full-screen readability on your display, and clean-Mac installation still need hands-on validation. Developer ID notarization requires your credentials.

See [release notes](docs/releases.md) and [icon/identity assets](docs/brand-assets.md) for more detail.
