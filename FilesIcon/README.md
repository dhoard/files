# Files macOS application icon

A macOS Dock/app icon representing Files' split-pane file explorer. The main icon has a transparent exterior with native-style rounded corners.

## What is included

- `FilesIcon.png` — clean 1024 × 1024 RGBA master, for previews and further edits.
- `FilesIcon.icns` — ready-to-use macOS application icon.
- `FilesIcon.iconset/` — all ten 1×/2× PNG representations, ready for `iconutil`.
- The Xcode `AppIcon` asset set from this package is integrated into the app at `Files/Assets.xcassets`; this folder keeps the master PNG/ICNS sources for regeneration.
- `source/original-generated.png` — original generated image before crop/transparent corners.
- `scripts/regenerate-icns.sh` — regenerate `.icns` from the iconset on macOS using Apple's `iconutil`.
- `scripts/embed-icon-in-app.sh` — insert an icon into an *unsigned* `.app` bundle; integrate into `build.sh` **before code signing**.
- `AI_INTEGRATION_PROMPT.md` — ready-to-paste implementation request for an AI coding agent.

## Path A: custom `build.sh` / manually assembled macOS `.app`

Copy `FilesIcon.icns` to `Files.app/Contents/Resources/FilesIcon.icns` during the build and configure `Files.app/Contents/Info.plist` with:

```xml
<key>CFBundleIconFile</key>
<string>FilesIcon</string>
```

Example (once the `.app` structure exists, **before code signing**):

```bash
./scripts/embed-icon-in-app.sh ./dist/.build/Files.app
```

From your project's own build script, copy/embed the icon from the project's chosen asset location. Do not depend on this extracted package's absolute path. The script updates `CFBundleIconFile` and requires `/usr/libexec/PlistBuddy` (standard on macOS).

**If signed:** Adding files or changing `Info.plist` after signing invalidates the signature. Embed the icon first, then sign the finished bundle. Reinstall the bundle to see the updated Dock icon.

## Path B: Xcode asset catalog (used by this project)

The `AppIcon` asset set has been integrated at `Files/Assets.xcassets` in this repository. The app target uses it through `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; the asset catalog compiler emits `Assets.car` and `AppIcon.icns` and sets `CFBundleIconName`/`CFBundleIconFile` to `AppIcon`. `FilesIcon/` is now source material for regenerating artwork, not a build dependency.

## Regenerating on macOS

```bash
./scripts/regenerate-icns.sh
```

The included `.icns` is usable as delivered; regeneration is optional. The script uses the included `.iconset` and Apple's `iconutil`. If you change the 1024px master image, regenerate the PNG sizes and then run `iconutil -c icns`.

## Verification

1. Build and install `Files.app` through your existing scripts.
2. Verify the bundle contains `Contents/Resources/FilesIcon.icns` (custom builds) or compiled asset-catalog icon (Xcode builds).
3. Inspect `Contents/Info.plist` and ensure the icon entry matches the chosen build strategy.
4. Verify the icon in Finder, Dock, and the macOS app switcher. The Dock may cache icons; replacing/reinstalling the bundle or relaunching Dock can help.

All image assets in this archive are provided for use in your Files project.
