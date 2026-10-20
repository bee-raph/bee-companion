# Releases

## 0.2.1 — 20 October 2026

Today and article content expand across the available window width. Added an explicit Shabbat-mode button to Today and kept its toolbar label visible. Stock results have separated rows and prominent Follow buttons; the full watchlist page scrolls when needed. Removed provider/candle-source labels from the stock presentation. Stock refresh is automatic and restarts when the watchlist changes; Hebrew calendar data also refreshes automatically.

Feed creation and editing now use a focused native sheet with editable name and URL fields, validation, Save/Cancel, and immediate backend synchronization. Added a complete Hebrew README translation alongside English, including setup, feature descriptions, synchronization, external providers, single-user deployment, operations, and limitations.

## 0.2.0 — 20 October 2026

Added a native RSS/Atom reader with up to three configurable feeds, summaries, original-article links, offline article caching, per-feed error states, and backend-synced settings. The backend bounds downloads, validates public destinations and redirects, and rejects XML entity expansion.

Added on-demand full-screen Shabbat mode (⌘⇧S; Esc to close), combining upcoming zmanim, location-based Open-Meteo weather, up to six selected stocks, and automatically rotating RSS columns. Refresh and rotation intervals sync with the backend. The screen keeps the display awake while open and releases that assertion on close. Shared token refresh avoids concurrent session-rotation requests during unattended updates.

Expanded setup, architecture, operations, single-user deployment, external-data requirements, and security documentation. Added a staged-file secret checker and additional native/backend tests.

## 0.1.3 — 20 October 2026

Fixed development packaging that could invalidate a running application's code signature. Builds are now assembled and signed in a separate staging folder, verified, then published by directory rename. The previous bundle is retained under `macos/dist/.previous-builds`; its executable is never overwritten or re-signed. If publication fails, the old bundle is restored. Quit and reopen after installing the update.

Search results also use dataset-and-symbol identities, distinguishing stock and options listings with the same symbol. Late responses from earlier searches cannot replace newer results.

The reported second-search crash was a macOS `CODESIGNING / Invalid Page` termination, not an application exception. Replacing the executable inside a running app caused it to fail validation when another code page was loaded.

## 0.1.2 — 20 October 2026

The calendar menu always contains actionable content, including permission guidance and refresh. Authorized calendars show checkmarks and select-all controls. Granting access refreshes the event store; returning from System Settings refreshes permission state. Deselecting every calendar correctly hides all Apple events.

Today’s horizontal zmanim strip sorts by occurrence time, highlights the next upcoming zman, and scrolls that strip into view on load and when the next time changes. The outer Today page keeps its position; times remain hours and minutes.

## 0.1.1 — 20 October 2026

Fixed alarm-window ownership: programmatically created AppKit windows now disable release-on-close because Swift retains and releases them. The original lifecycle reproduced a SIGSEGV in `objc_release` during autorelease-pool cleanup, matching the reported crash. A regression test closes and releases 25 windows safely. Existing alarms and local data are preserved.

The backend connection is unchanged: import `.runtime/client.companion-instance.json` in Settings and sign in with the private local owner credentials. The Docker backend must be running for synchronization; local editing and alarm delivery do not depend on it.
