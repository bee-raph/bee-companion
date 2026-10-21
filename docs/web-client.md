# Web client

Open the API service’s root URL, normally **http://127.0.0.1:8787/**, and sign in with the instance owner’s credentials. `/docs` and `/api/v1` remain available on the same service. No Node server or frontend build is required: FastAPI serves the packaged HTML, CSS, and JavaScript. The Docker build includes these files automatically.

The interface adapts from a bottom navigation bar on phones to a sidebar on larger screens, with system fonts, touch targets, rounded cards, light/dark appearance, and a close button on editors.

## Shared data

Tasks, notes, CRM contacts and activities, reminders, attachments, files/folders, watchlists, and preferences use the existing authenticated sync API. Edits persist in IndexedDB before sending. The outbox uses immutable operation IDs, optimistic revisions, paginated pulls, and explicit conflict resolution in Settings. Conflicts keep the local draft and the server version. Task status history uses the native client’s timestamp encoding. Existing record fields are preserved when editing other fields.

Each Today clock formats the current instant in its own configured IANA time zone, using the browser’s time-zone database for DST. Clock time, local date, and UTC offset refresh every second, independently of data sync. Tests cover both 2026 DST transitions in Jerusalem, London, and New York, different transition dates, non-DST zones, southern-hemisphere rules, and local dates across midnight.

The browser checks for changes every 15 seconds, on reconnect, on returning to the tab, and after saves. The desktop checks every 30 seconds while running and syncs on activation. Synced reminder changes flow through the desktop’s existing notification scheduler. **The web app does not schedule notifications and has no Shabbat mode.** It is for consulting and updating data.

Only one editing tab per origin holds the offline library lock, avoiding competing refresh-token rotation and cursor updates. Sessions are kept in sessionStorage; closing the tab requires signing in again. IndexedDB remains available after closing the tab. Signing out requires resolving pending work and clears the cached library and downloaded files.

Uploads are queued durably with their source Blob and server upload ID. Interrupted transfers ask the server for the current offset and continue in chunks up to 4 MiB. Completion verifies SHA-256 on the backend. Downloads verify the server checksum and retain a local copy for offline download. Web uploads are limited to **256 MiB per file** because the browser checksum API buffers the file in memory; use the desktop app for larger files. Browser storage quotas still apply.

The service worker caches only the application shell. API responses, credentials, and file contents are not placed in the service-worker cache. Reader/weather/market results are cached separately in the instance’s IndexedDB library. Use a current browser with IndexedDB, Web Locks, and Web Crypto. Remote deployments require HTTPS; localhost HTTP supports these browser features. The Docker API is published on all host IPv4 interfaces; other devices can reach it using the backend host address. Browser offline storage coordination and Web Crypto still require a secure browser context; native Windows HTTP connections work directly.

## Current coverage and limits

The web client includes global text search, task filters and archive/history, note editing, CRM activity and linked reminders, attachment upload/removal, file rename/move/duplicate/new versions/trash/restore, day/week/month agenda views, Hebrew calendar data, weather, world clocks, market instrument search and watchlists, and RSS reading.

Notes support bold, italic, underline, fonts/sizes, lists, separators, and inline PNG/JPEG insertion using RTF interchange. The RTF reader supports common text controls; it is not a complete RTF/RTFD renderer. Existing native RTFD image documents remain unchanged during metadata edits. Editing their note content asks before replacing the native image document. Full fidelity editing of arbitrary native RTFD documents remains a desktop feature.

This is an initial web implementation, **not complete desktop feature parity**. Remaining differences include the English-only web interface, simplified feed configuration, complete RTFD round-tripping/import/export, permanent file purge UI, arbitrary native file previews, and platform integrations such as Apple Calendar and Quick Look. Agenda times follow the browser’s time zone. There are no browser notifications or Shabbat display, by design.

## Validation

```sh
PYTHONPATH=backend .venv/bin/pytest backend/tests scripts/tests -q
node --test backend/tests/web/*.test.mjs
swift test --package-path macos
```

The integration suite verifies that separate browser/desktop sessions see each other’s changes, stale writes return conflicts, and operation retries are idempotent. Browser state tests cover queued drafts, cursor safety, conflict edits, task history, agenda overlap placement, and safe RTF rendering.

Deploy through `scripts/companionctl upgrade`; it backs up the existing deployment, builds the image, applies migrations, and restarts the API and worker without deleting volumes.
