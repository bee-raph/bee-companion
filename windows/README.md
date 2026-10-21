# Bee Companion for Windows

**Work in progress — for development and testing only. macOS is currently the only reliable version for everyday use. Use the macOS app for now.**

Native Windows client under development: **C# / .NET 10 / WinUI 3 / Windows App SDK**, with a separately testable SQLite and HTTP core. It uses the existing Python API without a web view.

## Current implementation

- Persistent, instance-isolated SQLite records, outbox, conflicts, change cursor, provider cache, and file-transfer queue.
- Atomic record/outbox writes; unsent draft coalescing; immutable sent operations; restart/retry recovery; rebasing of subsequent edits; explicit conflict resolution; merged native task histories.
- Instance identity validation, direct HTTP or HTTPS connections, serialized session refresh, bearer authentication, and Windows PasswordVault storage. Passwords are not stored.
- Background sync every 30 seconds and on window activation. Saves persist locally first. Manual sync is available in the toolbar.
- Native navigation, record forms, task completion/filter/archive/history, note RTF editing, contact details, activity browsing, reminder data editing, folders, file upload/download, trash restoration, settings, conflicts, watchlists, market search, RSS, weather/zmanim, and world clocks.
- Uploads use managed copies, streamed SHA-256, persisted session IDs, 4 MiB chunks, and server offsets for resume. Downloads are streamed and verified before publishing a cached copy. No 256 MiB web limit.
- Each world clock uses its own named time zone and that zone’s DST rules at the displayed instant. Tests cover spring/autumn transitions in Jerusalem, London, and New York.

**This is a development build with incomplete feature parity and no signed installer.** The native interface supports light/dark appearance, responsive dashboard cards, timezone clocks, a stock watchlist, and a month calendar with a selected-day schedule. Windows notification scheduling, Shabbat display, full agenda timelines, calendar integration, native file-change tracking, activity creation/editing, attachment pickers inside editors, localization, and MSIX signing/install/update validation remain unfinished. RTFD image notes are read-only while metadata can be updated.

## Run tests on macOS, Linux, or Windows

Install the .NET 10 SDK, then:

```sh
dotnet test windows/Companion.Core.Tests/Companion.Core.Tests.csproj
```

Core tests do not reference WinUI or Windows APIs. Their fake HTTP/backend implementations test failure/retry behavior; they do not substitute for Windows UI testing.

## Validation

Run the core suite and publish the native project on Windows. Core tests cover persisted retry recovery, concurrent token refresh, conflicts, stale editor snapshots, file checksums, resumed uploads, percentage formatting, and per-zone DST boundaries. Native ARM64 publishing includes XAML compilation. Visual and interactive checks require Windows screen access.

Startup must reach the main page. Milestones and exceptions are written to `%LOCALAPPDATA%/BeeCompanion/startup.log`. Published builds require `Companion.Windows.pri` for native WinUI styles; `build.ps1` verifies its presence.

## Windows build

Use a Windows 10/11 machine, a Windows VM (Windows ARM64 on Apple Silicon is suitable), or a Windows build runner with:

- .NET 10 SDK.
- Visual Studio with WinUI application development tooling and a Windows SDK supporting target 10.0.19041.0 or later. The project targets Windows 10 build 19041 and later.
- Network access for NuGet restore.

From PowerShell at the repository root:

```powershell
./windows/build.ps1 -Architecture x64
# On Windows ARM64:
./windows/build.ps1 -Architecture ARM64
```

When building directly from the Parallels share `\\Mac\windows`, keep generated files local to Windows:

```powershell
$env:BeeBuildRoot = Join-Path $env:LOCALAPPDATA 'BeeCompanionBuild\shared'
& '\\Mac\windows\build.ps1' -Architecture ARM64
```

This reads the shared source without copying it. Intermediate files, test binaries, and the published app stay under `BeeBuildRoot`; the output executable is in `dist/win-arm64/` under that directory. Use `dotnet test` and `dotnet publish` directly if local script execution is restricted; there is no need to weaken the execution policy.

The initial development output is an unpackaged, self-contained folder under `windows/dist/win-x64/` or `windows/dist/win-arm64/`. Run `Companion.Windows.exe` from that folder. Keep the whole folder together. MSIX distribution and signing are a later Windows validation step; no certificate is included in the repository.

Alternatively open `windows/BeeCompanion.slnx` in Visual Studio, choose the corresponding architecture, and build the Windows project.

## Connect to the existing deployment

In Settings, import the instance’s `client.companion-instance.json`, then sign in with the same owner login and password used on the Mac and web clients. Local data is stored beneath `%LOCALAPPDATA%/BeeCompanion/<instance UUID>/`. The public configuration file is separate from the Windows credential vault.

The API is published on all host IPv4 interfaces at port 8787. Use the backend host address in the instance configuration when connecting from another device. Import the configuration in Settings and sign in with the instance owner credentials. The client checks the backend instance UUID before sending changes. The database has no published port. There is no HTTPS gateway or certificate pinning.

## Windows verification handoff

1. Run the core tests and native build; retain the first compiler diagnostics if compilation fails.
2. Launch the app and import a test-instance configuration.
3. Sign in; create/edit a task offline; restart the app; reconnect and sync.
4. Confirm edits arrive on macOS/web and edits from those clients appear in Windows.
5. Test concurrent edits and both conflict choices.
6. Interrupt/restart an upload and verify downloaded bytes against SHA-256.
7. Validate the native rich editor with Unicode, formatted RTF, and legacy RTFD notes.
8. Implement and validate notifications, closed-app scheduling, wake recovery, Shabbat mode, and packaging on Windows before claiming native feature parity.

## Preconfigured deployments

Pass `-InstanceConfigurationPath <path-to-instance-json>` to `build.ps1` to include a public instance configuration beside the executable. On first launch, Windows imports that file automatically; an existing configuration in the user's local app data takes precedence. Credentials are never bundled: sign in in Settings if this PC does not already have a session. The executable and window use the Mac app's artwork, packaged as a multiresolution Windows icon.
