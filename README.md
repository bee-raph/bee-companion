# Bee Companion

[English](#english) · [עברית](#hebrew)

<a id="english"></a>

## English

Bee Companion is a **native macOS single user utility** that combines work tools, a local agenda, and an on-demand Shabbat display. SwiftUI and AppKit provide the interface. A Docker Compose backend stores work, settings, and files; local SQLite storage supports offline editing.

Each deployment has exactly one owner. There is no public registration, collaboration, or shared workspace. Another person needs a separate deployment and configuration file; everyone can use the same application build.

## Features

- **Today:** due tasks, reminders, local weather, three world clocks, Hebrew date, zmanim, and a compact stock watchlist. The layout expands with the window. Clocks omit seconds; the zmanim strip advances to the next upcoming time.
- **Tasks:** title, description, due date or date/time, status, attachments, reminders, TXT/RTF export, and sharing. Click the circle or select Done to move a task into the second **Archived** tab. Click its checkmark or choose Restore to return it to To do in **Active**. Completion and archive state synchronize together.
- **CRM:** open **CRM** in the Workspace sidebar to manage companies and individuals with identity, company and tax details, multiple addresses, emails, telephone/mobile/WhatsApp numbers, and client/prospect/provider/simple-contact categories. Each contact has one autosaved rich-text note using the same editor as Notes: bold, italic, underline, fonts, sizes, lists, separators, and inline images. Rich text and embedded images synchronize with the contact and remain editable offline. Contact activity supports phone calls, sent emails, WhatsApp messages, and invoices, each with a title, description, date, optional reminder, and documents. Emails open your mail app; mobile and WhatsApp links open a WhatsApp conversation. Validated international numbers display their country flag and formatting, including offline. Enter numbers with `+` and a country calling code, one per line. Contacts, actions, attachment links, and reminders use the authenticated backend sync and database, with local offline editing and conflict handling. Deleting a contact also removes its activity and reminders; attached files stay in the library.
- **Files:** an app-owned folder tree, resumable upload/download, immutable versions, SHA-256 verification, rename/move/duplicate, trash/restore, confirmed permanent deletion, offline copies, Quick Look, default-app opening, and external-edit detection. A single click on a name or icon opens the file or folder. Colored icons identify file types. Moving files preserves attachment links.
- **Notes:** a native rich-text body editor with bold, italic, underline, font, font size, inline images, bullet and numbered lists, and separators. Formatting affects the selection or future typing at the caret. Autosave serializes immutable snapshots on a background queue and flushes pending edits on close or quit. Markdown is an import/export format. Export converts supported formatting, links, lists, separators, and embedded images; Markdown cannot express every rich-text font or layout. RTFD export preserves inline images; standard RTF export contains text. Notes include title, description, search, attachments, and sharing.
- **Attachments:** **Attach files…** opens the macOS picker for any local file, including multiple selections, in tasks, notes, and reminders. No library import is required beforehand. The app prepares a managed copy and checksum off the UI thread and queues synchronization. Copies also appear in Files. Removing an attachment keeps the file. Note and reminder deletion requires confirmation from both the list’s **−** control and the editor’s Trash button.
- **Alarms:** standalone or linked reminders, full-description popup windows while running, macOS notifications when closed, snooze, dismiss, missed-occurrence recovery, and one-time/daily/weekday/weekly/monthly recurrence. Recurrence preserves local wall-clock time across daylight-saving changes; monthly recurrence skips months without the selected day.
- **Agenda:** Outlook-style Day and Week timelines covering all 24 hours, half-hour guides, an all-day strip, a current-time indicator, and separate columns for overlapping events. Month combines a date grid with the selected day’s timeline. Today, previous/next, and the date picker control navigation. Selected Apple calendars appear alongside tasks and reminders; external calendar editing opens Calendar. Calendar selection and view mode synchronize, while Apple event data stays local.
- **Hebrew calendar:** Gregorian/Hebrew dates, holidays, fasts, Rosh Chodesh, Torah portions, Omer, candle lighting, Havdalah, and daily zmanim. Israel/diaspora, location, and time zone are configurable.
- **Weather and clocks:** temperature, high/low, feels-like temperature, humidity, and wind; up to three IANA world-clock zones. Today and Shabbat use the same configured city, coordinates, time zone, and zmanim cache. Today refreshes weather every ten minutes; saved conditions remain available offline.
- **Stocks:** London Strategic Edge search, watchlist, latest available minute-candle close, change against the previous completed daily session, timestamps, and editable TradingView mappings. Quotes refresh automatically. Candle-derived prices are not live tick quotes. There is no brokerage connection or trading.
- **RSS:** up to three public RSS/Atom feeds, configured by name and URL in Settings. Add/Edit opens an editable popup. Articles have publication dates, plain-text summaries, cached offline reading, and links to original pages. Downloads are bounded, XML entities are disabled, and private-network destinations are rejected.
- **Shabbat mode:** activate with the button on Today or the toolbar, **⌘⇧S**, or **View → Open Shabbat Mode**. A separate full-screen display shows upcoming zmanim, local weather, up to six selected instruments, and the latest ten headlines per feed simultaneously. Refresh is configurable from one minute to one hour. The display stays awake and updates without mouse input. **Esc** closes it. Activation is on demand.
- **Languages and native controls:** English (default), Hebrew, French, Russian, and Spanish under **Settings → Language**, including Hebrew right-to-left layout. User content retains its original language. Native selection, alternating rows, **+ / −** controls, keyboard shortcuts, drag and drop, light/dark appearance, and macOS sharing are supported. WhatsApp and LocalSend use user-controlled compose/transfer flows.

## Get started

### 1. Prerequisites and source

Use macOS 14 or later on Apple Silicon or Intel, Xcode 15 or later with command-line tools, Python 3.11 or later, Git, and Docker Desktop with Compose v2. Launch Xcode once to complete installation and accept its license. Internet access is required to obtain dependencies and external data. A London Strategic Edge key is needed only for stocks.

```sh
xcodebuild -version
swift --version
python3 --version
docker compose version
git clone https://github.com/bee-raph/bee-companion.git
cd bee-companion
```

### 2. One-click native build

Double-click **Build.command** in Finder. It checks the build tools, builds a universal Apple Silicon/Intel application and DMG, signs locally, and reveals the app in Finder. Docker does not need to be running for this build. The terminal reports errors and waits for Return when launched interactively.

Outputs:

```text
macos/dist/Bee Companion.app
macos/dist/Bee Companion.dmg
```

Equivalent command-line builds:

```sh
./Build.command
scripts/build-macos debug
scripts/build-macos release
```

The app is staged and signed separately before publication by directory rename. Retained bundles are stored under `macos/dist/.previous-builds/`. Quit and reopen the app to use the built version. Generated applications and installers are ignored by Git.

Local signing supports your own build. Notarized distribution requires Developer ID credentials and a notarytool Keychain profile:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build-macos release
```

Without those credentials the script produces a locally signed, unnotarized app and DMG. Keep certificates and signing secrets outside the repository.

### 3. Initialize the backend

Start Docker Desktop, then run:

```sh
scripts/companionctl init --name "My Bee Companion" --login owner --port 8787
scripts/companionctl status
scripts/companionctl validate
```

The initializer securely prompts for the owner password and optional London Strategic Edge key. Use a password of at least 12 characters and save it in your password manager. It creates permission-restricted `.runtime/` configuration and secrets, generates an instance UUID and database password, builds the backend image, starts PostgreSQL, applies migrations, creates the owner, and starts API/worker services. Rerunning preserves the instance and its data. Validation should report `{"status":"ready"}`.

The API listens only at `http://127.0.0.1:8787`; the database has no published port. Separate persistent volumes hold database data, file objects, and backups. No Supabase, Redis, object-storage server, mail server, or browser frontend is required.

### 4. Connect and configure

Open the built app. In **Settings → Import instance configuration**, choose:

```text
<checkout>/.runtime/client.companion-instance.json
```

The file contains the instance name, UUID, API address, and compatible version, with no password or provider secret. The app verifies the backend identity. Sign in as `owner` with the password chosen during initialization, then synchronize. The sidebar and Settings show availability, pending changes, and errors. If the server reports an expired session, sign in again; backend readiness and authentication are separate.

In Settings, choose the interface language and up to three clock zones. Set city, latitude, longitude, time zone, and Israel/diaspora preferences for location-dependent times and weather. In Agenda, enable Apple Calendar and grant full Calendar access; select the calendars to display. Denied access can be changed in **System Settings → Privacy & Security → Calendars**. App-owned agenda items work without that permission.

Under **RSS & Shabbat mode**, add up to three feed names/URLs, choose automatic refresh and up to six instruments, and save the settings. Follow instruments from Stocks. Use the Shabbat button or shortcut to open the display. Enable notifications when configuring alarms.

Keep Docker running for synchronization and fresh external data. Tasks and notes remain editable offline; changes upload when the backend is available and you are signed in. File content is available offline when cached. Sharing requires suitable destination applications and recipient confirmation.

## External data

**London Strategic Edge is the sole stock provider.** Obtain your own key from [the provider](https://londonstrategicedge.com/) and review its [API documentation](https://londonstrategicedge.com/docs/api/). Initialization stores it only in `.runtime/lse_api_key`, mounted into the backend as a secret. For an existing instance, edit that restricted file locally and restart the backend. Never put the key in source, client configuration, command arguments, logs, or commits. Without a key, stock endpoints report that configuration is missing; other features remain usable.

Search uses the instrument catalog; prices use minute candles and previous-session daily data with caching and request limits. Coverage, delay, quotas, and permitted use depend on the provider account. Use stock/ETF listings; options-chain pricing is not implemented. Each deployment needs its own key and must comply with the provider’s [data terms](https://londonstrategicedge.com/terms).

Weather comes from [Open-Meteo](https://open-meteo.com/); Hebrew observances and zmanim use [Hebcal](https://www.hebcal.com/home/developer-apis). The configured public endpoints need no additional key. Coordinates are sent to these services for location-dependent results. Feed, weather, and market caches have independent lifetimes: up to five minutes, ten minutes, and one minute respectively. Provider availability and terms apply.

## Storage and synchronization

SQLite/GRDB stores each local record and outgoing mutation atomically. Saves schedule automatic sync after a short pause. The client pushes revision-checked, idempotent operations and pulls ordered changes on launch, reconnect, manual sync, and periodically while running. Pull pages and cursors commit atomically. Conflicts preserve both drafts for explicit resolution in Settings.

Backend storage includes tasks and archive state, rich note bodies and inline images, folders, file metadata and immutable bytes, attachment links, reminders and occurrence actions, watchlist/mappings, and preferences: language, clocks, location, Hebrew calendar settings, feeds, Shabbat refresh and selected stocks, calendar selection, and agenda view mode. Uploads resume by session/offset and verify SHA-256 before finalization; downloads verify checksums. File renames and moves change metadata rather than physical object paths. External edits can be uploaded as new versions.

Apple event data, macOS permissions, connection configuration, Keychain credentials, window layout, and disposable local caches remain on the Mac. Instances have isolated databases, caches, and sessions. Offline changes remain queued rather than being treated as successfully uploaded. The backend uses FastAPI, SQLAlchemy/Alembic, PostgreSQL 17, private filesystem storage, and a PostgreSQL-backed worker.

## Operations and another user

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

`stop` preserves data. **Do not run `docker compose down -v` on an instance you need.** Backups contain a PostgreSQL dump, referenced immutable objects, instance/version manifest, and checksums. The worker schedules nightly backups while running, retaining seven daily and four weekly copies. Export to another disk for protection against loss of the Mac. Protect backups because they contain private data and password hashes. Export requires the API to be running.

Upgrade backs up, stops writes, migrates, and checks readiness. Migration failure leaves writes disabled for recovery. Restore validates database and objects and revokes sessions. Password reset is a local administrative action and also revokes sessions; there is no email recovery service.

For another owner, create an isolated instance with its own loopback port:

```sh
scripts/companionctl --instance-dir .runtime-second init \
  --name "Second Companion" --login owner --port 8788
```

Use `--instance-dir` before subsequent commands. Each instance has separate volumes, secrets, owner, UUID, and client configuration. Import the desired configuration into the same app build; switching requires pending changes and conflicts to be resolved.

## Local verification and limits

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt pytest
PYTHONPATH=backend .venv/bin/pytest backend/tests scripts/tests -q
swift test --package-path macos
python3 scripts/check_translations.py
python3 scripts/check_secrets.py --staged
```

Checks cover storage/sync, full settings persistence, files, note formatting and Markdown export, task archives, agenda overlaps and daylight-saving boundaries, RSS, authentication, and packaging. The translation audit checks all five catalogs for matching keys, duplicate keys, empty entries, format arguments, and static UI references. Verification runs locally; the repository has no GitHub Actions workflows. API documentation is available at `http://127.0.0.1:8787/docs`.

There is no login launch or background alarm helper. Closing the last main window quits the app. macOS governs closed-app notifications; a sleeping or powered-off Mac cannot guarantee an on-time popup. The client schedules the earliest 60 occurrences within 30 days. File cache eviction is not implemented. Calendar permissions, notification delivery, sharing apps, screen readability, and installation on another Mac need validation on the target machine. Notarization requires Developer ID credentials.

Deployment secrets, local databases, generated apps/installers, and signing material are ignored by Git. Use HTTPS for any independently configured remote deployment; the packaged deployment is loopback-only. See [icon and identity assets](docs/brand-assets.md).

---

<a id="hebrew"></a>

## עברית

Bee Companion הוא **כלי עזר מקורי ל־macOS למשתמש יחיד**, המשלב כלי עבודה, סדר יום מקומי ותצוגת שבת לפי דרישה. הממשק משתמש ב־SwiftUI וב־AppKit. שרת Docker Compose שומר עבודה, הגדרות וקבצים, ומסד SQLite מקומי מאפשר עריכה ללא חיבור.

לכל מופע יש בעלים אחד בלבד. אין הרשמה ציבורית, שיתוף פעולה או סביבת עבודה משותפת. משתמש נוסף צריך מופע וקובץ תצורה נפרדים; כולם יכולים להשתמש באותה אפליקציה בנויה.

## תכונות

- **היום:** משימות, תזכורות, מזג אוויר, שלושה שעונים עולמיים, תאריך עברי, זמני היום ורשימת מניות מקוצרת. הממשק מתרחב עם החלון, השעונים אינם מציגים שניות ורצועת זמני היום מתקדמת לזמן הבא.
- **משימות:** כותרת, תיאור, מועד או תאריך ושעה, מצב, קבצים מצורפים, תזכורות, ייצוא TXT/RTF ושיתוף. לחיצה על העיגול או בחירת בוצע מעבירה את המשימה ללשונית השנייה, **בארכיון**. לחיצה על סימן הביקורת או בחירת שחזור מחזירה אותה לביצוע בלשונית **פעילות**. מצב הביצוע והארכוב מסתנכרנים יחד.
- **CRM:** פתחו את **CRM** בסרגל הצד של סביבת העבודה לניהול חברות ואנשים פרטיים עם פרטי זהות, חברה ומס, כתובות מרובות, דוא״ל, טלפונים וניידים ו־WhatsApp. סוגי קשר: לקוח, לקוח פוטנציאלי, ספק ואיש קשר. לכל איש קשר הערה עשירה אחת הנשמרת אוטומטית באותו עורך של ההערות: הדגשה, נטייה, קו תחתון, גופנים וגדלים, רשימות, מפרידים ותמונות בגוף ההערה. העיצוב והתמונות מסתנכרנים עם איש הקשר וזמינים לעריכה ללא חיבור. ניתן לתעד שיחה, דוא״ל, הודעת WhatsApp וחשבונית שנשלחו, עם כותרת, תיאור, תאריך, תזכורת ומסמכים. דוא״ל פותח את יישום הדואר ונייד פותח שיחת WhatsApp. מספרים מוצגים בתבנית בינלאומית עם דגל המדינה גם ללא חיבור; יש להזין מספר אחד בשורה עם `+` וקידומת מדינה. אנשי קשר, פעילות, צירופים ותזכורות נשמרים מקומית ומסתנכרנים לשרת ולמסד הנתונים עם טיפול בהתנגשויות. מחיקת איש קשר מסירה גם פעילות ותזכורות, אך המסמכים נשארים בספריית הקבצים.
- **קבצים:** עץ תיקיות בבעלות האפליקציה, העלאה והורדה שניתנות לחידוש, גרסאות שאינן נדרסות, בדיקת SHA-256, שינוי שם, העברה, שכפול, סל ושחזור, מחיקה סופית באישור, עותקים לא מקוונים, Quick Look, פתיחה באפליקציית ברירת המחדל וזיהוי עריכה חיצונית. לחיצה אחת על השם או הסמל פותחת את הקובץ או התיקייה. סמלים צבעוניים מזהים סוגי קבצים, והעברה אינה שוברת צירופים.
- **הערות:** עורך טקסט עשיר מקורי עם הדגשה, הטיה, קו תחתון, גופן, גודל, תמונות, רשימות תבליטים ומספור וקווי הפרדה. העיצוב חל על הבחירה או על הקלדה עתידית בנקודת הסמן. שמירה אוטומטית מקודדת תמונות מצב בלתי משתנות בתור רקע ושומרת עריכות ממתינות בסגירה או ביציאה. Markdown משמש לייבוא ולייצוא. הייצוא ממיר עיצוב נתמך, קישורים, רשימות, קווי הפרדה ותמונות; הוא אינו תומך בכל גופן או פריסה של טקסט עשיר. ייצוא RTFD שומר תמונות, ו־RTF רגיל מכיל טקסט. הערות כוללות גם כותרת, תיאור, חיפוש, צירופים ושיתוף.
- **צירופים:** **צירוף קבצים…** פותח את בוחר הקבצים של macOS במשימות, בהערות ובתזכורות, עם אפשרות לבחור כמה קבצים מקומיים. אין צורך בייבוא מוקדם לספרייה. האפליקציה מכינה עותק מנוהל וחתימה מחוץ לתהליכון הממשק ומתזמנת סנכרון. העותקים מופיעים גם בקבצים. הסרת צירוף שומרת את הקובץ. מחיקת הערה או תזכורת דורשת אישור, הן בכפתור **−** ברשימה והן בכפתור הסל בעורך.
- **תזכורות והתראות:** תזכורות עצמאיות או מקושרות, חלון עם התיאור המלא בזמן שהאפליקציה פועלת, התראות macOS כשהיא סגורה, נודניק, סגירה ושחזור מועדים שהוחמצו. נתמכת חזרה חד־פעמית, יומית, בימי שבוע נבחרים, שבועית וחודשית. החזרה שומרת על השעה המקומית בשינויי שעון; חודש ללא היום שנבחר מדולג.
- **סדר יום:** צירי זמן יומיים ושבועיים בסגנון Outlook עם כל 24 השעות, קווי חצי שעה, אזור יום שלם, קו זמן נוכחי ועמודות נפרדות לאירועים חופפים. חודש משלב רשת תאריכים עם ציר הזמן של היום הנבחר. היום, הקודם/הבא ובוחר התאריך שולטים בניווט. לוחות Apple שנבחרו מוצגים לצד משימות ותזכורות, ועריכת אירוע חיצוני פותחת את Calendar. בחירת הלוחות ומצב התצוגה מסתנכרנים, בעוד תוכן אירועי Apple נשאר מקומי.
- **לוח עברי:** תאריכים עבריים ולועזיים, חגים, צומות, ראש חודש, פרשות, עומר, הדלקת נרות, הבדלה וזמני היום. אפשר להגדיר ישראל/תפוצות, מיקום ואזור זמן.
- **מזג אוויר ושעונים:** טמפרטורה, מינימום ומקסימום, תחושת חום, לחות ורוח, ועד שלושה אזורי זמן עולמיים מסוג IANA. היום ומצב שבת משתמשים באותה עיר, קואורדינטות, אזור זמן ומטמון זמני היום. מזג האוויר מתרענן במסך היום כל עשר דקות, ונתונים שמורים זמינים ללא חיבור.
- **מניות:** חיפוש London Strategic Edge, רשימת מעקב, מחיר הסגירה האחרון הזמין של נר דקה, שינוי לעומת יום המסחר היומי הקודם שהושלם, זמן הנתון ומיפויי TradingView הניתנים לעריכה. הנתונים מתרעננים אוטומטית. מחירים המבוססים על נרות אינם נתוני טיק חיים. אין חיבור לברוקר או ביצוע מסחר.
- **RSS:** עד שלוש הזנות RSS/Atom ציבוריות עם שם וכתובת בהגדרות. הוספה ועריכה פותחות חלונית ניתנת לעריכה. כתבות כוללות תאריך פרסום, תקציר טקסט, קריאה שמורה ללא חיבור וקישור למקור. ההורדות מוגבלות, ישויות XML חסומות ויעדי רשת פרטיים נדחים.
- **מצב שבת:** הפעלה בכפתור במסך היום או בסרגל, **⌘⇧S**, או **View → Open Shabbat Mode**. חלון נפרד במסך מלא מציג יחד זמני יום קרובים, מזג אוויר, עד שש מניות ועשר הכותרות האחרונות מכל הזנה. מרווח הרענון הוא דקה עד שעה. המסך נשאר ער ומתעדכן ללא עכבר. **Esc** סוגר אותו. ההפעלה היא לפי דרישה.
- **שפות ובקרות מקוריות:** אנגלית כברירת מחדל, עברית, צרפתית, רוסית וספרדית ב־**הגדרות ← שפה**, כולל ממשק עברי מימין לשמאל. תוכן המשתמש נשאר בשפת המקור. נתמכים בחירה מקורית, שורות מתחלפות, **+ / −**, קיצורי מקשים, גרירה, מראה בהיר/כהה ושיתוף macOS. WhatsApp ו־LocalSend משתמשים בתהליכי שליחה ואישור של המשתמש.

## תחילת עבודה

### 1. דרישות וקוד המקור

נדרשים macOS 14 ומעלה על Apple Silicon או Intel, ‏Xcode 15 ומעלה עם כלי שורת הפקודה, Python 3.11 ומעלה, Git ו־Docker Desktop עם Compose v2. פתחו את Xcode פעם אחת להשלמת ההתקנה ואישור הרישיון. נדרש אינטרנט להורדת תלויות ונתונים חיצוניים. מפתח London Strategic Edge נחוץ רק למניות.

```sh
xcodebuild -version
swift --version
python3 --version
docker compose version
git clone https://github.com/bee-raph/bee-companion.git
cd bee-companion
```

### 2. בניית האפליקציה בלחיצה

לחצו פעמיים על **Build.command** ב־Finder. הסקריפט בודק כלי בנייה, בונה אפליקציה אוניברסלית ל־Apple Silicon ול־Intel וקובץ DMG, חותם מקומית ומציג את האפליקציה ב־Finder. Docker אינו נדרש לבנייה זו. החלון מציג שגיאות וממתין ל־Return בהפעלה אינטראקטיבית.

הקבצים המתקבלים:

```text
macos/dist/Bee Companion.app
macos/dist/Bee Companion.dmg
```

פקודות בנייה מקבילות:

```sh
./Build.command
scripts/build-macos debug
scripts/build-macos release
```

האפליקציה נבנית ונחתמת בתיקיית הכנה נפרדת ומפורסמת באמצעות שינוי שם תיקייה. עותקים שמורים נמצאים ב־`macos/dist/.previous-builds/`. צאו ופתחו מחדש לשימוש בבנייה המתקבלת. Git מתעלם מאפליקציות ומתקינים שנוצרו.

חתימה מקומית מתאימה לבנייה לשימוש עצמי. להפצה מאומתת נדרשים פרטי Developer ID ופרופיל notarytool ב־Keychain:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build-macos release
```

ללא האישורים מתקבלים אפליקציה ו־DMG עם חתימה מקומית וללא notarization. שמרו אישורים וסודות חתימה מחוץ למאגר.

### 3. אתחול השרת

הפעילו Docker Desktop והריצו:

```sh
scripts/companionctl init --name "My Bee Companion" --login owner --port 8787
scripts/companionctl status
scripts/companionctl validate
```

האתחול מבקש באופן מאובטח סיסמת בעלים ומפתח London Strategic Edge אופציונלי. השתמשו בסיסמה בת 12 תווים לפחות ושמרו אותה במנהל סיסמאות. הוא יוצר תצורה וסודות בהרשאות מוגבלות תחת `.runtime/`, מייצר UUID למופע וסיסמת מסד, בונה תמונת שרת, מפעיל PostgreSQL, מבצע מיגרציות, יוצר בעלים ומפעיל API ועובד רקע. הפעלה חוזרת שומרת את המופע ונתוניו. האימות אמור להחזיר `{"status":"ready"}`.

ה־API מאזין רק ב־`http://127.0.0.1:8787`; למסד אין פורט מפורסם. Volumes נפרדים שומרים מסד, קבצים וגיבויים. אין צורך ב־Supabase, ‏Redis, שרת אחסון אובייקטים, שרת דואר או ממשק דפדפן.

### 4. חיבור והגדרה

פתחו את האפליקציה הבנויה. ב־**Settings → Import instance configuration** בחרו:

```text
<checkout>/.runtime/client.companion-instance.json
```

הקובץ מכיל שם מופע, UUID, כתובת API וגרסה תואמת, ללא סיסמה או סוד ספק. האפליקציה בודקת את זהות השרת. התחברו בתור `owner` עם הסיסמה שבחרתם באתחול וסנכרנו. סרגל הצד וההגדרות מציגים זמינות, שינויים ממתינים ושגיאות. אם החיבור מדווח שפג תוקף ההזדהות, התחברו מחדש; תקינות השרת והזדהות הן בדיקות נפרדות.

בהגדרות בחרו שפה ועד שלושה אזורי זמן לשעונים. הגדירו עיר, קו רוחב, קו אורך, אזור זמן וישראל/תפוצות עבור מזג אוויר וזמנים תלויי מיקום. בסדר היום הפעילו גישה ללוחות Apple, אשרו גישה מלאה ובחרו לוחות להצגה. ניתן לשנות הרשאה שנדחתה תחת **System Settings → Privacy & Security → Calendars**. פריטי האפליקציה זמינים ללא הרשאה זו.

תחת **RSS ומצב שבת**, הוסיפו עד שלוש הזנות עם שמות וכתובות, בחרו מרווח רענון ועד שש מניות ושמרו. הוסיפו מניות למעקב במסך המניות. פתחו מצב שבת בכפתור או בקיצור. בעת הגדרת התראות, הפעילו הרשאת התראות.

השאירו Docker פועל לסנכרון ולנתונים חיצוניים עדכניים. ניתן לערוך משימות והערות ללא חיבור; השינויים יישלחו כשהשרת זמין ויש הזדהות. קבצים זמינים ללא חיבור כשיש עותק שמור. שיתוף דורש אפליקציית יעד מתאימה ואישור נמענים.

## נתונים חיצוניים

**London Strategic Edge הוא ספק המניות היחיד.** קבלו מפתח משלכם [מהספק](https://londonstrategicedge.com/) ועיינו ב[תיעוד API](https://londonstrategicedge.com/docs/api/). האתחול שומר אותו רק ב־`.runtime/lse_api_key`, המותקן בשרת כסוד. במופע קיים ערכו את הקובץ המקומי המוגבל והפעילו מחדש את השרת. אין להכניס מפתח לקוד, לתצורת הלקוח, לארגומנטים, ליומנים או לקומיטים. ללא מפתח, שירות המניות מדווח שחסרה הגדרה; יתר התכונות זמינות.

החיפוש משתמש בקטלוג, והמחירים בנרות דקה ובנתונים יומיים מהמסחר הקודם, עם מטמון והגבלת בקשות. כיסוי, השהיה, מכסות ושימוש מותר תלויים בחשבון. השתמשו ברישומי מניות ו־ETF; תמחור שרשראות אופציות אינו ממומש. כל מופע צריך מפתח משלו ולעמוד ב[תנאי הנתונים](https://londonstrategicedge.com/terms).

מזג האוויר מגיע מ־[Open-Meteo](https://open-meteo.com/), וחגים וזמני היום מ־[Hebcal](https://www.hebcal.com/home/developer-apis). נקודות הקצה הציבוריות המוגדרות אינן דורשות מפתח נוסף. הקואורדינטות נשלחות לשירותים אלה לחישוב תלוי מיקום. מטמוני הזנות, מזג אוויר ושוק עצמאיים: עד חמש דקות, עשר דקות ודקה בהתאמה. חלים תנאי הספקים וזמינותם.

## אחסון וסנכרון

SQLite/GRDB שומר אטומית רשומה מקומית ופעולה לשליחה. שמירה מתזמנת סנכרון לאחר הפסקה קצרה. הלקוח דוחף פעולות ניתנות לחזרה עם בדיקת גרסה ומושך שינויים מסודרים בהפעלה, בחיבור מחדש, בסנכרון ידני ובמחזוריות בזמן פעילות. דפי שינויים וסמנים נשמרים אטומית. התנגשות שומרת את שתי הטיוטות לפתרון מפורש בהגדרות.

השרת שומר משימות וארכוב, גוף הערות עשיר ותמונות, תיקיות, מטא־נתונים וקבצים בגרסאות שאינן נדרסות, צירופים, תזכורות ופעולות על מופעים, רשימת מעקב ומיפויים והעדפות: שפה, שעונים, מיקום, לוח עברי, הזנות, רענון שבת ומניות נבחרות, בחירת לוחות ומצב סדר היום. העלאות מתחדשות לפי סשן והיסט ונבדקות ב־SHA-256 לפני השלמה; גם הורדות נבדקות. שינוי שם והעברה משנים מטא־נתונים ולא נתיב פיזי. ניתן להעלות עריכה חיצונית כגרסה חדשה.

תוכן אירועי Apple, הרשאות macOS, תצורת החיבור, אישורי Keychain, מבנה החלונות ומטמונים מקומיים זמניים נשארים על ה־Mac. לכל מופע מסד, מטמון וסשנים נפרדים. שינוי לא מקוון נשאר בתור ואינו מסומן כאילו הועלה. השרת משתמש ב־FastAPI, ‏SQLAlchemy/Alembic, ‏PostgreSQL 17, אחסון קבצים פרטי ועובד רקע מבוסס PostgreSQL.

## תפעול ומשתמש נוסף

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

`stop` שומר את הנתונים. **אין להריץ `docker compose down -v` על מופע שברצונכם לשמור.** גיבוי מכיל ייצוא PostgreSQL, קבצים מקושרים, מניפסט מופע וגרסה וחתימות אימות. עובד הרקע מתזמן גיבויים ליליים כשהשרת פועל ושומר שבעה יומיים וארבעה שבועיים. ייצאו לדיסק אחר להגנה מאובדן ה־Mac. הגנו על הגיבויים משום שהם מכילים מידע פרטי וחתימות סיסמאות. הייצוא דורש API פועל.

שדרוג מגבה, עוצר כתיבות, מבצע מיגרציה ובודק תקינות. כישלון מיגרציה משאיר כתיבות חסומות לצורך התאוששות. שחזור מאמת מסד וקבצים ומבטל סשנים. איפוס סיסמה הוא פעולה מקומית של מנהל וגם הוא מבטל סשנים; אין שירות התאוששות בדוא״ל.

לבעלים נוסף, צרו מופע מבודד עם פורט מקומי נפרד:

```sh
scripts/companionctl --instance-dir .runtime-second init \
  --name "Second Companion" --login owner --port 8788
```

העבירו `--instance-dir` לפני פקודות ההמשך. לכל מופע volumes, סודות, בעלים, UUID ותצורת לקוח משלו. ייבאו את התצורה הרצויה לאותה אפליקציה; מעבר דורש פתרון שינויים והתנגשויות ממתינים.

## בדיקות מקומיות ומגבלות

```sh
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt pytest
PYTHONPATH=backend .venv/bin/pytest backend/tests scripts/tests -q
swift test --package-path macos
python3 scripts/check_translations.py
python3 scripts/check_secrets.py --staged
```

הבדיקות מכסות אחסון וסנכרון, שמירת הגדרות מלאה, קבצים, עיצוב הערות וייצוא Markdown, ארכוב משימות, חפיפות ושעון קיץ בסדר היום, RSS, הזדהות ואריזה. בדיקת התרגומים מאמתת התאמת מפתחות בחמש שפות, כפילויות, ערכים ריקים, מצייני פורמט והפניות ממשק קבועות. הבדיקות רצות מקומית; אין במאגר תהליכי GitHub Actions. תיעוד API זמין ב־`http://127.0.0.1:8787/docs`.

אין הפעלה אוטומטית בכניסה או עוזר התראות ברקע. סגירת החלון הראשי האחרון מסיימת את האפליקציה. macOS שולט בהתראות כשהיא סגורה; Mac ישן או כבוי אינו מבטיח חלון במועד. הלקוח מתזמן את 60 המופעים הקרובים בתוך 30 יום. אין פינוי אוטומטי של מטמון הקבצים. יש לבדוק הרשאות לוח, התראות, אפליקציות שיתוף, קריאות המסך והתקנה על Mac אחר במכשיר היעד. Notarization דורש אישורי Developer ID.

Git מתעלם מסודות פריסה, מסדים מקומיים, אפליקציות ומתקינים שנוצרו וחומרי חתימה. לפריסה מרוחקת עצמאית השתמשו ב־HTTPS; הפריסה המסופקת מקומית בלבד. ראו [נכסי הסמל והזהות](docs/brand-assets.md).
