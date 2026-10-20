# Bee Companion

[English](#english) · [עברית](#hebrew)

<a id="english"></a>

Bee Companion is a **native macOS application for one user**, combining everyday work tools with a readable, on-demand Shabbat display. The interface is SwiftUI and AppKit, not a website or an embedded browser. A local Docker Compose backend stores synchronized work and files; the Mac keeps its own SQLite database so everyday editing continues when Docker or the internet is unavailable.

**This is a single-user application, not a multi-user service.** A deployment has exactly one owner account, no public registration, and no collaboration or shared workspaces. Give another person a separate backend instance and configuration file. The same native app can connect to any compatible instance, one at a time.

## Features

### Interface language

Choose **Settings → Language**: English (default), Hebrew, French, Russian, or Spanish. The interface changes immediately; Hebrew uses right-to-left layout. This preference belongs to the active instance and syncs with the backend as `user_settings.language` (`en`, `he`, `fr`, `ru`, `es`). Offline changes persist locally and upload when the backend is available. Pulled settings update the interface automatically. Existing settings without a language use English. User-written notes, feed articles, file names, and Apple Calendar event content retain their original language.

### Today and work tools

Lists and tables use native macOS selection, alternating rows, and compact **+ / −** controls below the collection. Select an item to enable removal. Tasks, notes, alarms, and library files move to Trash; removing a feed or followed instrument removes it from that list. In Files, **+** imports files and **New folder** creates a folder; in Stocks, **+** focuses instrument search.

- **Today:** a dashboard of tasks, upcoming reminders, three world clocks, the Hebrew calendar, zmanim, and followed instruments. The dashboard expands across the available window width, including when maximized. Clocks and displayed timestamps omit seconds. The zmanim strip advances independently to the next upcoming time.
- **Tasks:** title, description, due date or date/time, To do/In progress/Done/Cancelled status, independent archive state, file attachments, linked reminders, TXT/RTF export, and sharing.
- **Files:** an app-owned folder hierarchy with upload/download, resumable transfers, checksums, immutable file versions, rename/move/duplicate, trash/restore, confirmed permanent deletion, offline copies, Quick Look, default-app opening, and detection of externally edited working copies. Moving a file preserves its attachments.
- **Notes:** Markdown source and preview or native RTF editing, title/description, autosave, full-text search, import/export, and attachments. Format conversion creates a copy to preserve the original.
- **Alarms:** complete-description popup windows while the app runs, local macOS notification fallback when closed, snooze, missed-occurrence recovery, and one-time/daily/weekday/weekly/monthly recurrence. Recurrence preserves wall-clock time across daylight-saving changes; monthly dates skip months without that day.
- **Agenda:** read selected Apple calendars alongside app tasks/reminders, with day/week/month ranges and calendar grids. Calendar access is explicitly granted through macOS, and Apple event data stays on the Mac. Editing external appointments remains in Apple Calendar.
- **Hebrew calendar:** Hebrew/Gregorian dates, Israel/diaspora selection, holidays, fasts, Rosh Chodesh, Torah portions, Omer, candle lighting/Havdalah, and daily zmanim through Foundation and Hebcal. Location-dependent times require coordinates and a time zone.
- **Stocks:** London Strategic Edge instrument search, watchlist, latest available minute candle close, change against the previous completed daily bar, timestamps, and editable TradingView symbol mappings. Prices are derived from candles.
- **Sharing:** the native share picker, plain-text WhatsApp compose flow, and LocalSend handoff for files. Destination applications must be installed or available. The user confirms recipients and sending; nothing is sent automatically.

### RSS reader

Configure **up to three RSS or Atom feeds** in **Settings → RSS & Shabbat mode**. Each has a name and public HTTP/HTTPS feed URL. **Add feed** and **Edit** open a native popup with editable name and URL fields; saving it queues the feed changes for backend synchronization. The reader groups articles by feed, displays publication dates and plain-text summaries, and opens original articles in the default browser. It does not crawl full articles or load remote scripts and images.

The backend downloads and parses feeds, limits download size, checks redirects, rejects private-network destinations, and disables XML entity expansion. Public feeds on standard HTTP/HTTPS ports are supported; authenticated feeds and private LAN feeds are not. Failed feeds retain saved articles and show their unavailable/stale state. Previously loaded articles are also cached on the Mac for offline reading.

### Shabbat mode

Click the labeled **Shabbat mode** button on Today or in the toolbar, press **⌘⇧S**, or use the **View → Open Shabbat Mode** menu item. A separate native full-screen window shows all of the following on one page:

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
5. In **Settings → RSS & Shabbat mode**, click **Add feed** and enter its name and RSS/Atom URL in the popup, then choose **Save feed**. Repeat for up to three feeds. To change an existing feed, use **Edit**. Choose refresh/rotation intervals and up to six stocks, then click **Save reader & Shabbat settings**. These settings use the same offline queue and revision-checked sync as the rest of the app.
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

---

<a id="hebrew"></a>

רשימות וטבלאות משתמשות בבחירה ובשורות מתחלפות בסגנון macOS, עם כפתורי **+ / −** בתחתית הרשימה. בחרו פריט כדי לאפשר הסרה. משימות, הערות, תזכורות וקבצי הספרייה מועברים לסל; הזנות ומניות מוסרות מהרשימה. בקבצים, **+** מייבא קבצים ו־**תיקייה חדשה** יוצר תיקייה; במניות, **+** מעביר את המיקוד לחיפוש.


### שפת הממשק

ב־**הגדרות ← שפה** ניתן לבחור אנגלית (ברירת המחדל), עברית, צרפתית, רוסית או ספרדית. הממשק מתעדכן מיד, ובעברית מוצג מימין לשמאל. ההעדפה שייכת למופע הפעיל ומסתנכרנת עם השרת בשדה `user_settings.language` באמצעות הקודים `en`, `he`, `fr`, `ru`, `es`. שינוי ללא חיבור נשמר מקומית ונשלח כשהשרת זמין; העדפה שמתקבלת מהשרת מעדכנת את הממשק אוטומטית. הגדרות ישנות ללא שפה משתמשות באנגלית. תוכן שהמשתמש כתב, כתבות RSS, שמות קבצים ואירועי Apple Calendar נשארים בשפת המקור.


# עברית

[חזרה לאנגלית](#english)

Bee Companion היא **אפליקציית macOS מקורית למשתמש יחיד**, המשלבת כלי עבודה יומיומיים עם מסך שבת קריא שניתן להפעיל לפי דרישה. הממשק בנוי ב־SwiftUI וב־AppKit; הוא אינו אתר אינטרנט ואינו דפדפן מוטמע. שרת מקומי המנוהל באמצעות Docker Compose שומר את העבודה והקבצים המסונכרנים. במקביל, ה־Mac מחזיק מסד נתונים מקומי מסוג SQLite, כך שאפשר להמשיך לערוך גם כאשר Docker או חיבור האינטרנט אינם זמינים.

**האפליקציה מיועדת למשתמש יחיד בלבד, ולא לשירות מרובה משתמשים.** בכל פריסה יש חשבון בעלים אחד בלבד, ללא הרשמה ציבורית, שיתוף פעולה בין משתמשים או סביבות עבודה משותפות. עבור אדם נוסף יש ליצור מופע שרת נפרד וקובץ תצורה נפרד. אותה אפליקציה מקורית יכולה להתחבר למופעים תואמים שונים, אחד בכל פעם.

## תכונות

### מסך היום וכלי עבודה

- **Today — היום:** לוח בקרה עם משימות, תזכורות קרובות, עד שלושה שעונים עולמיים, לוח שנה עברי, זמני היום וניירות ערך במעקב. לוח הבקרה מתפרס על רוחב החלון הזמין, גם כשהחלון מוגדל. השעונים וחותמות הזמן המוצגות אינם כוללים שניות. פס זמני היום נגלל בנפרד אל הזמן הבא שעתיד להתרחש.
- **Tasks — משימות:** כותרת, תיאור, תאריך יעד או תאריך ושעה, מצבים To do / In progress / Done / Cancelled, ארכוב נפרד ממצב הביצוע, קבצים מצורפים, תזכורות מקושרות, ייצוא TXT/RTF ושיתוף.
- **Files — קבצים:** עץ תיקיות בבעלות האפליקציה, העלאה והורדה, חידוש העברות שנקטעו, בדיקת תקינות באמצעות סכומי ביקורת, גרסאות קבצים שאינן נדרסות, שינוי שם, העברה ושכפול, סל מחזור ושחזור, מחיקה סופית לאחר אישור, עותקים מקומיים, Quick Look, פתיחה ביישום ברירת המחדל וזיהוי שינויים בעותקי עבודה שנערכו ביישום חיצוני. העברת קובץ אינה שוברת את הקישורים אליו מתוך משימות או הערות.
- **Notes — הערות:** עריכת מקור ותצוגה מקדימה של Markdown, או עריכת RTF מקורית; כותרת ותיאור, שמירה אוטומטית, חיפוש בטקסט המלא, ייבוא וייצוא וקבצים מצורפים. המרה בין פורמטים יוצרת עותק כדי לשמור על המקור.
- **Alarms — התראות ותזכורות:** חלון המציג את התיאור המלא כשהאפליקציה פועלת, התראות macOS מקומיות כשהיא סגורה, נודניק, שחזור תזכורות שהוחמצו וחזרה חד־פעמית, יומית, בימי שבוע נבחרים, שבועית או חודשית. תזכורות חוזרות שומרות על השעה המקומית במעבר לשעון קיץ או חורף; חזרה חודשית מדלגת על חודשים שבהם התאריך שנבחר אינו קיים.
- **Agenda — סדר יום:** הצגת לוחות Apple שנבחרו לצד המשימות והתזכורות של האפליקציה, בטווחי יום, שבוע וחודש ובתצוגת רשת לוח שנה. הגישה ללוחות ניתנת במפורש דרך macOS, ואירועי Apple נשארים על ה־Mac. עריכת אירועים חיצוניים מתבצעת באפליקציית Calendar.
- **לוח שנה עברי:** תאריכים עבריים ולועזיים, בחירת מנהגי ישראל או חו״ל, חגים, צומות, ראש חודש, פרשות השבוע, ספירת העומר, הדלקת נרות והבדלה וזמני היום באמצעות Foundation ו־Hebcal. זמנים התלויים במיקום מחייבים קואורדינטות ואזור זמן.
- **Stocks — ניירות ערך:** חיפוש מכשירים פיננסיים באמצעות London Strategic Edge, רשימת מעקב, מחיר הסגירה האחרון הזמין של נר בן דקה, שינוי ביחס לנר היומי הקודם שהושלם, חותמות זמן ומיפוי ניתן לעריכה לסימול TradingView. המחירים נגזרים מנתוני נרות.
- **שיתוף:** חלונית השיתוף המקורית של macOS, פתיחת הודעת WhatsApp עם טקסט פשוט והעברת קבצים ל־LocalSend. יישומי היעד חייבים להיות מותקנים או זמינים. המשתמש מאשר את הנמענים ואת השליחה; דבר אינו נשלח אוטומטית.

### קורא RSS

אפשר להגדיר **עד שלוש הזנות RSS או Atom** תחת **Settings → RSS & Shabbat mode**. לכל הזנה יש שם וכתובת HTTP/HTTPS ציבורית. הכפתורים **Add feed** ו־**Edit** פותחים חלונית מקורית שבה ניתן לערוך את השם ואת הכתובת. שמירת החלונית מוסיפה את השינויים לתור הסנכרון עם השרת. הקורא מקבץ כתבות לפי הזנה, מציג תאריכי פרסום ותקצירים כטקסט פשוט ופותח כתבות מקור בדפדפן ברירת המחדל. הוא אינו סורק את הכתבה המלאה ואינו טוען סקריפטים או תמונות מרוחקות.

השרת מוריד ומפענח את ההזנות, מגביל את גודל ההורדה, בודק הפניות, חוסם יעדים ברשתות פרטיות ומונע הרחבת ישויות XML. נתמכות הזנות ציבוריות בפורטים הרגילים של HTTP/HTTPS; הזנות המחייבות הזדהות והזנות ברשת מקומית פרטית אינן נתמכות. כאשר הזנה אינה זמינה, כתבות שכבר נשמרו נשארות מוצגות עם סימון מתאים. כתבות שנטענו נשמרות גם ב־Mac לקריאה ללא חיבור.

### מצב שבת

לחצו על הכפתור המסומן **Shabbat mode** במסך Today או בסרגל הכלים, הקישו **⌘⇧S**, או השתמשו בתפריט **View → Open Shabbat Mode**. ייפתח חלון מקורי נפרד במסך מלא, המציג באותו עמוד:

- זמני היום הקרובים, תוך הדגשת הזמן הבא.
- מזג אוויר מקומי, טמפרטורה, טמפרטורות יומיות מרבית ומזערית, לחות ורוח.
- עד שישה ניירות ערך נבחרים מרשימת המעקב.
- עד שלוש עמודות RSS שכותרותיהן ותקציריהן מתחלפים אוטומטית.

התצוגה משתמשת בטקסט גדול, ברקע כהה עם ניגודיות גבוהה וללא הצגת שניות. המסך נשאר פעיל כל עוד החלון פתוח. לאחר ההפעלה, התוכן מתעדכן ללא שימוש בעכבר. **Esc** סוגר את חלון השבת ומשחרר את מניעת כיבוי המסך. ההפעלה היא לפי דרישה; אין הפעלה אוטומטית ביום שישי או כיבוי מתוזמן.

בהגדרות ניתן לבחור רענון כל דקה עד שעה, החלפת כותרות כל 10 עד 120 שניות ואת ניירות הערך שיוצגו. בחירות אלה, כתובות ההזנות והעדפות המיקום מסתנכרנות עם השרת. מזג האוויר וזמני היום משתמשים בקואורדינטות העיר ובאזור הזמן שהוגדרו, ולא במעקב מיקום רציף. למטמוני ההזנות, מזג האוויר והשוק יש זמני תוקף נפרדים, ולכן בדיקת רענון אינה בהכרח בקשה חדשה לספק בכל פעם. מטמון ההזנות נשמר עד חמש דקות, מטמון מזג האוויר עשר דקות ומטמון נתוני השוק דקה.

## תחילת עבודה

### 1. התקנת דרישות מוקדמות

נדרשים:

- macOS 14 ומעלה, על Apple Silicon או Intel.
- Xcode 15 ומעלה וכלי שורת הפקודה לצורך בניית האפליקציה המקורית. יש להפעיל את Xcode פעם אחת כדי להשלים התקנת רכיבים ואישור הרישיון.
- Docker Desktop עם Docker Compose v2, כשהוא פועל לפני הקמת השרת.
- Python 3.11 ומעלה עבור כלי הניהול.
- Git וחיבור אינטרנט להורדת תלויות ונתונים חיצוניים.
- מפתח API של London Strategic Edge אם רוצים חיפוש ומחירי מניות. ניתן להקים את יתר התכונות גם בלעדיו.

בדיקת הכלים:

```sh
xcodebuild -version
swift --version
python3 --version
docker compose version
```

שכפול קוד המקור:

```sh
git clone https://github.com/bee-raph/bee-companion.git
cd bee-companion
```

### 2. אתחול השרת הפרטי

הריצו:

```sh
scripts/companionctl init --name "My Bee Companion" --login owner --port 8787
```

האתחול יוצר תיקיית `.runtime/` עם הרשאות מוגבלות, מגריל סיסמה למסד הנתונים ומזהה UUID למופע, ומבקש באופן מאובטח את מפתח London Strategic Edge ואת סיסמת הבעלים. בחרו סיסמה בת 12 תווים לפחות ושמרו אותה במנהל הסיסמאות. אפשר להשאיר את מפתח הספק ריק בשלב הראשון; ממשקי המניות יציגו הודעה שהוא חסר. המפתחות והסיסמאות אינם מופיעים בארגומנטים של פקודות או בקובץ התצורה של הלקוח.

הפקודה בונה את תמונת השרת, מפעילה PostgreSQL, מחילה מיגרציות, יוצרת את חשבון הבעלים היחיד ומפעילה את ה־API ואת תהליך הרקע. ניתן להריץ אותה שוב עבור אותו מופע: הנתונים ופרטי הבעלים הקיימים נשמרים. ה־API מאזין בכתובת `http://127.0.0.1:8787`; PostgreSQL אינו נחשף בפורט של המחשב המארח. אין צורך ב־Supabase, במסד נתונים בענן, בשרת דואר או בממשק דפדפן.

בדיקת תקינות:

```sh
scripts/companionctl status
scripts/companionctl validate
```

הפקודה האחרונה אמורה להחזיר `{"status":"ready"}`. השאירו את Docker Desktop פועל כאשר נדרש סנכרון או מידע חיצוני עדכני. סגירת Docker אינה מוחקת את העבודה ואינה מונעת עריכת משימות והערות מקומית.

### 3. בנייה ופתיחה של האפליקציה המקורית

לשימוש מקומי:

```sh
scripts/build-macos debug
open "macos/dist/Bee Companion.app"
```

הסקריפט מוריד את תלויות Swift, בונה חבילת `.app` אמיתית, מעתיק את האייקון והמשאבים וחותם עליה מקומית. כל גרסה חדשה נבנית בתיקיית ביניים נפרדת ומתפרסמת באמצעות שינוי שמות תיקיות; קובץ הרצה של אפליקציה פעילה אינו נדרס. גרסאות קודמות נשמרות תחת `macos/dist/.previous-builds/`. יש לצאת מהאפליקציה ולפתוח אותה מחדש כדי להשתמש בגרסה מעודכנת.

לבניית אפליקציה אוניברסלית עבור Intel ו־Apple Silicon וקובץ DMG:

```sh
scripts/build-macos release
```

חתימה מקומית מתאימה לבנייה עצמית. הפצה שעברה notarization דורשת Developer ID של Apple ופרופיל notarytool מוגדר ב־Keychain:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build-macos release
```

הסקריפט מדלג במפורש על notarization כאשר פרטים אלה אינם זמינים. יש לשמור זהויות חתימה, אישורים ופרטי notary מחוץ למאגר.

### 4. חיבור האפליקציה למופע שלכם

פתחו **Settings → Import instance configuration** ובחרו:

```text
<your checkout>/.runtime/client.companion-instance.json
```

מכיוון ש־`.runtime` היא תיקייה מוסתרת, הקישו **⌘⇧G** בחלונית בחירת הקובץ והדביקו את הנתיב המלא. התחברו עם שם המשתמש והסיסמה שבחרתם באתחול. האפליקציה בודקת את UUID המופע ואת גרסת ה־API, שומרת אסימוני התחברות ב־Keychain של macOS, ולאחר הסנכרון אמורה להציג **Everything is up to date**.

קובץ התצורה שנוצר מכיל רק שם מופע, UUID, כתובת API וגרסת פרוטוקול. הוא אינו מכיל סיסמה, מפתח מניות או הרשאת ניהול. אין להעתיק את תיקיית זמן הריצה של משתמש אחר. בפריסה חדשה **לא** נוצר קובץ `initial-login.txt`: השתמשו בסיסמה שהקלדתם, או אפסו אותה מקומית לפי ההוראות בהמשך.

### 5. הגדרת לוחות שנה, מיקום, הזנות ומצב שבת

1. במסך **Agenda**, לחצו על **Enable Apple Calendar** והעניקו גישה מלאה ללוחות. אם הגישה נדחתה, הפעילו את Bee Companion תחת **System Settings → Privacy & Security → Calendars**, חזרו לאפליקציה ורעננו. תפריט הלוחות מציג סימוני בחירה, בחירה וביטול של כל הלוחות והסברים כאשר אין לוחות זמינים.
2. במסך **Settings**, הזינו שם עיר, קו רוחב, קו אורך ואזור זמן בפורמט IANA, לדוגמה `Asia/Jerusalem`. הקואורדינטות מוזנות ידנית ומשמשות לחישובי מזג האוויר ו־Hebcal. בחרו מנהגי ישראל או חו״ל.
3. הגדירו עד שלושה אזורי זמן של IANA, מופרדים בפסיקים, עבור השעונים העולמיים.
4. הוסיפו מכשירים פיננסיים במסך **Stocks**. בדקו את המיפוי ל־TradingView כאשר שמות הספק והבורסה שונים.
5. תחת **Settings → RSS & Shabbat mode**, לחצו **Add feed**, הזינו בחלונית שם וכתובת RSS/Atom ובחרו **Save feed**. חזרו על הפעולה לעד שלוש הזנות. לשינוי הזנה קיימת השתמשו ב־**Edit**. בחרו מרווחי רענון והחלפת כותרות ועד שש מניות, ואז לחצו **Save reader & Shabbat settings**. ההגדרות משתמשות באותו תור עבודה לא מקוון ובאותו סנכרון מבוסס גרסאות של שאר האפליקציה.
6. פתחו את **RSS Reader** כדי לטעון כתבות. לאחר מכן לחצו **⌘⇧S** או על **Shabbat mode** כדי לפתוח את מצב השבת. השאירו את האפליקציה ואת Docker פועלים לעדכונים ללא התערבות. הקישו **Esc** כדי לצאת.

## דרישת London Strategic Edge

יש להנפיק מפתח אישי דרך [London Strategic Edge](https://londonstrategicedge.com/data). השרת משתמש ב־[SDK הרשמי ל־Python](https://github.com/londonstrategicedge/lse-data), שגרסתו מקובעת ב־`backend/requirements.txt`. המפתח נשמר רק בתיקיית הפריסה הפרטית ומועבר לקונטיינרים כסוד של Compose. הוא אינו נכלל באפליקציה המקורית, אינו מועבר על ידי הלקוח בתוך כתובת ציבורית ואינו נכלל במאגר הזה.

במופע קיים ניתן לערוך מקומית את `.runtime/lse_api_key` ולהפעיל מחדש את השרת. יש לשמור על הרשאות מוגבלות לקובץ. אין להדביק את המפתח בקוד, בדוגמאות README, בדיווחי תקלות או ב־commits.

החיפוש משתמש בקטלוג הספק; המחירים מבוססים על נרות של דקה ועל נתונים יומיים קודמים, עם מטמון ותקציב בקשות בשרת. זמינות, כיסוי שווקים, השהיה, מכסות ושימוש מותר תלויים בחשבון הספק ובתנאים העדכניים שלו. סימולים מסוימים מופיעים בכמה מערכי נתונים, ולכן זהות תוצאת חיפוש מורכבת ממערך הנתונים ומהסימול. מתאם המחירים בגרסה זו משתמש בממשק הנרות הרגיל ואינו מממש תמחור שרשראות אופציות. עבור רשימת המעקב השתמשו ברישומי מניות וקרנות סל.

אין חיבור לברוקר או ביצוע פקודות מסחר. כל משתמש עצמאי זקוק למפתח משלו ועליו לפעול לפי [תנאי הנתונים של הספק](https://londonstrategicedge.com/terms). אין להפעיל את הפריסה כשירות להפצה מחדש של נתוני שוק.

נתוני מזג האוויר מגיעים מ־[Open-Meteo](https://open-meteo.com/), עם ייחוס על המסך. יש לבדוק את תנאי השירות בהתאם לשימוש המתוכנן, במיוחד בפריסה מסחרית. נתוני הלוח העברי מגיעים מ־[Hebcal](https://www.hebcal.com/home/developer-apis). שתי האינטגרציות אינן דורשות מפתח עבור נקודות הקצה הציבוריות המוגדרות. מפרסמי RSS קובעים את זמינות ההזנות ואת תנאי השימוש בתוכן שלהם.

## כיצד הסנכרון עובד

מסד GRDB/SQLite שעל ה־Mac הוא מקור הנתונים המיידי של הממשק. שמירת פריט מבצעת באותה טרנזקציה גם שמירה מקומית וגם הוספת שינוי יוצא לתור. שינויים שטרם נשלחו מאוחדים; פעולות שכבר נשלחו שומרות על מזהים יציבים, כך שניסיון חוזר אינו יוצר כפילויות.

הלקוח דוחף שינויים עם מספרי גרסה ומושך סמן שינויים עמיד מהשרת בהפעלה, בחיבור מחדש, בסנכרון ידני ובאופן מחזורי כשהוא פעיל. ה־API בודק גרסה צפויה, שומר קבלות לפעולות חוזרות ומסדר את הקצאת יומן השינויים בעזרת נעילת advisory של PostgreSQL. דפי שינויים והסמנים שלהם נשמרים אטומית בלקוח. אם לקוח אחר שינה רשומה, האפליקציה שומרת את הטיוטה המקומית ואת גרסת השרת לפתרון מפורש בהגדרות; היא אינה משליכה בשקט עריכות של הערות או קבצים. סימוני מחיקה והיסטוריה נשמרים, ולכן לסמנים אין כרגע תאריך תפוגה.

משימות, הערות, תיקיות, מידע על קבצים, קישורי קבצים מצורפים, תזכורות, פעולות על מופעי תזכורות, רשימת המעקב והעדפות משתמש מסתנכרנים. תצורת RSS, רענון והחלפת כותרות במצב שבת, מניות נבחרות, קואורדינטות העיר והעדפות הלוח העברי הם חלק מההעדפות המסונכרנות. אירועי Apple, החלטות הרשאה, מבנה החלונות ומטמונים מקומיים נשארים על המכשיר.

בהעלאת קבצים נשמרים מזהה ההעברה והמיקום שאושר גם בלקוח וגם בשרת. התוכן נבדק באמצעות סכום ביקורת לפני שהוא הופך לגרסה שאינה נדרסת. גם הורדות נבדקות. קובץ עבודה ששונה ביישום אחר יכול להיטען כגרסה חדשה. נתיבי הקבצים הפיזיים בשרת מבוססים על מזהים שנוצרו, ולא על שמות התיקיות הנראים בממשק.

## ניהול, גיבוי ושחזור

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

איפוס סיסמה הוא פעולת ניהול מקומית שמבטלת הפעלות התחברות קיימות. אין שירות שחזור באמצעות דוא״ל.

Volumes נפרדים של Docker מכילים את מסד PostgreSQL, הקבצים שאינם נדרסים והגיבויים. הפקודה `stop` שומרת את הנתונים. **אין להשתמש ב־`docker compose down -v` על מופע שברצונכם לשמור.** הגדרות האחסון של Docker Desktop קובעות באיזה דיסק מארח נשמרים ה־volumes; תיקיית המופע קובעת היכן נשמרים התצורה והסודות.

גיבויים כוללים dump של PostgreSQL, אובייקטים מקושרים, מניפסט מופע וגרסה וסכומי ביקורת. תהליך הרקע מתזמן גיבוי יומי כשהוא פועל ושומר שבעה גיבויים אחרונים וארבעה שבועיים. גיבוי מקומי נשאר באותו מחשב עד שהוא מיוצא לדיסק אחר. ייצוא מחייב שקונטיינר ה־API יפעל. יש להגן על קובצי הגיבוי: הם מכילים עבודה פרטית וגיבובי סיסמאות של חשבון הבעלים.

שדרוג יוצר גיבוי, עוצר כתיבות של ה־API ותהליך הרקע, בונה ומחיל מיגרציות ואז בודק מוכנות. אם מיגרציה נכשלת, הכתיבות נשארות מושבתות לצורך התאוששות. גם שחזור עוצר כתיבות, מאמת אובייקטים, משחזר את מסד הנתונים והקבצים ומבטל הפעלות התחברות. שחזור לפריסה אחרת משתמש בזהות המופע של פריסת היעד ובחשבון הבעלים ונתוני העבודה ששוחזרו. תהליך גיבוי ושחזור נבדק מול פריסה שנייה מבודדת.

### משתמש או מופע נוספים

```sh
scripts/companionctl --instance-dir .runtime-second init \
  --name "Second Companion" --login owner --port 8788
```

לכל מופע יש פרויקט Compose, מסד נתונים, קבצים, גיבויים, סודות, UUID וחשבון בעלים יחיד משלו. בפעולות ניהול נוספות יש להעביר `--instance-dir` **לפני** שם הפקודה. ייבאו באפליקציה המקורית את קובץ התצורה שנוצר עבור אותו מופע. לפני החלפת מופע יש לסנכרן עבודה ממתינה ולפתור התנגשויות. מסדי הנתונים המקומיים, מטמוני הקבצים וההפעלות ב־Keychain מופרדים לפי UUID של המופע.

## פיתוח ובדיקות

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt pytest
PYTHONPATH=backend .venv/bin/pytest backend/tests scripts/tests -q
swift test --package-path macos
```

סכמת ה־API נשמרת במאגר בקובץ `backend/openapi.json`. לאחר שינוי ב־API:

```sh
FILES_ROOT=/tmp/bee-companion-api PYTHONPATH=backend \
  .venv/bin/python scripts/export-openapi.py
```

תהליך CI מריץ בדיקות שרת ואריזה, בודק שהסכמה מעודכנת ומריץ בדיקות של האפליקציה המקורית. תיעוד API זמין בכתובת `http://127.0.0.1:8787/docs`; נקודות קצה פרטיות מחייבות הזדהות.

השרת מבוסס על FastAPI, SQLAlchemy/Alembic, PostgreSQL 17, אחסון קבצים פרטי ותהליך רקע המשתמש ב־PostgreSQL. ישויות העבודה עם הגרסאות משתמשות במעטפת `records` משותפת, סוגים מאומתים ותוכן בעל ערכי מחרוזת. להפעלות התחברות, גרסאות קבצים, העלאות, משימות רקע, מטמון ספקים, קבלות פעולות ויומן שינויים יש טבלאות ייעודיות. הערות עשירות שומרות RTF בקידוד base64 וטקסט שחולץ במעטפת ההערה. האפליקציה המקורית משתמשת ב־SwiftUI/AppKit, GRDB/FTS5, EventKit, UserNotifications, Keychain ו־URLSession.

## אבטחה ומגבלות מעשיות

- חשבון בעלים יחיד, גיבוב סיסמאות Argon2id, אסימונים אטומים שנשמרים כגיבוב בשרת, ריענון פרטי התחברות מתחלפים, שמירת הפעלות ב־Keychain והגבלת ניסיונות התחברות. אין נקודת קצה להרשמה.
- ה־API מאזין רק בכתובת loopback של IPv4; PostgreSQL אינו נחשף. הלקוח המקורי מקבל HTTP רק עבור כתובות loopback. אירוח מרוחק אינו כלול בפריסה זו ויחייב HTTPS ותכנון אבטחה ופריסה מתאים.
- `.runtime*`, קובצי סביבה, מסדי נתונים מקומיים, מטמונים, מפתחות ואישורי חתימה, אפליקציות ומתקינים שנוצרו ותיקיות סודות מוחרגים מ־Git. אין להוסיף אותם בכוח. אפשר לבדוק קבצים הממתינים ל־commit באמצעות `python3 scripts/check_secrets.py --staged`.
- האפליקציה אינה שירות התראות שפועל תמיד ברקע. סגירת החלון הראשי האחרון מסיימת אותה. macOS שולט בהתראות כשהאפליקציה סגורה; מחשב במצב שינה או כבוי אינו יכול להבטיח חלון תזכורת בזמן המדויק. בכל פתיחה הלקוח מתזמן את 60 המופעים הקרובים ביותר בטווח של 30 ימים.
- קבצים שנשמרו במטמון אינם מפונים אוטומטית. סימון לשימוש לא מקוון שומר את ההעדפה ומוריד את התוכן; ניהול מגבלת גודל המטמון עדיין אינו ממומש.
- הבדיקות האוטומטיות מכסות שמירה וסנכרון, מצבי לוח שנה, תזכורות חוזרות, בעלות חלונות התראה, זהויות תוצאות חיפוש, פענוח RSS ומגבלותיו, הגנה מפני כתובות פרטיות, העדפות ואריזה בטוחה. חלוניות ההרשאה האמיתיות של Calendar, מסירת התראות בפועל, יישומי שיתוף חיצוניים, קריאות המסך המלא על הצג שלכם והתקנה על Mac נקי עדיין דורשים בדיקה ידנית. notarization של Apple מחייבת את פרטי החתימה שלכם.

למידע נוסף: [הערות גרסה](docs/releases.md) ו־[קובצי האייקון והזהות החזותית](docs/brand-assets.md).
