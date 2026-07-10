# WindowsWindows

WindowsWindows gives each open macOS window its own live Dock tile. Each tile uses a snapshot of the window, follows the window's lifecycle, and brings that exact window to the front when clicked.

The app is intentionally minimal: it runs in the background, has no settings window, and stores its configuration in a JSON file.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later to build from source
- Accessibility permission, used to discover and focus windows
- Screen Recording permission, used to create window previews

## Build and run

Open `WindowsWindows.xcodeproj` in Xcode, select the **WindowsWindows** scheme, and run it.

You can also build a release from Terminal:

```sh
xcodebuild \
  -project WindowsWindows.xcodeproj \
  -scheme WindowsWindows \
  -configuration Release \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  build

open .build/Build/Products/Release/WindowsWindows.app
```

The first launch asks for Accessibility access and requests Screen Recording access. On macOS 26, if the system opens **System Settings > Privacy & Security > Screen & System Audio Recording** without adding the app, use `+` to add the installed `WindowsWindows.app`, enable it, and restart the app.

The scheme's post-build action signs embedded executables and the app bundle. It uses an ad-hoc signature by default when the repository author's local identity is unavailable. To use a stable Apple Development or self-signed identity, pass its SHA-1 hash in the environment:

```sh
WINDOWSWINDOWS_SIGNING_IDENTITY=YOUR_IDENTITY_SHA1 xcodebuild \
  -project WindowsWindows.xcodeproj \
  -scheme WindowsWindows \
  -configuration Release \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

A stable identity is preferable for regular local use because changing the signature can cause macOS to ask for permissions again.

## Configuration

On first launch, WindowsWindows creates:

```text
~/Library/Application Support/WindowsWindows/config.json
```

Default configuration:

```json
{
  "bundleIdentifiers" : [],
  "refreshInterval" : 2,
  "scopeMode" : "allExceptListed",
  "snapshotInterval" : 5
}
```

- `allExceptListed` tracks every non-system app except the listed bundle identifiers.
- `onlyListed` tracks only the listed bundle identifiers.
- `refreshInterval` controls window discovery, in seconds.
- `snapshotInterval` controls preview refreshes, in seconds.

Quit and reopen WindowsWindows after editing the file. Apple system processes, CleanShot X capture overlays, WindowsWindows itself, and generated proxy apps are always excluded.

Diagnostics are appended to:

```text
~/Library/Application Support/WindowsWindows/diagnostics.jsonl
```

Generated per-window proxy bundles are stored under `~/Library/Application Support/WindowsWindows/ProxyApps/` and are managed automatically.

## How it works

WindowsWindows combines macOS Accessibility APIs, Core Graphics window metadata, and ScreenCaptureKit. For every discovered window, it creates a lightweight proxy app bundle whose Dock icon is the current window preview. Clicking that proxy sends an activation message back to the main app, which raises the corresponding real window.

## Limitations

- Dock tiles are separate foreground proxy applications, so they can also appear briefly in app-switching UI depending on macOS behavior.
- Some applications expose unusual Accessibility metadata; their windows may be omitted or may not focus reliably.
- Without Screen Recording permission, window tracking still works but preview capture can fail.
- GitHub release archives are ad-hoc signed and are not notarized. Review the source and required permissions before use; Gatekeeper may require an explicit first-open confirmation.

## License

WindowsWindows is available under the [MIT License](LICENSE).
