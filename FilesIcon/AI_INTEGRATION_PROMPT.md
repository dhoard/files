# Files app icon integration — implementation prompt

You are modifying my existing macOS file explorer project named **Files**. I have provided a ZIP of icon assets. Integrate these assets into the existing application and build/install workflow; do not redesign the icon.

## Requirements

1. Inspect the repository first to determine whether Files is built with SwiftUI, AppKit, `swiftc`, `xcodebuild`, XcodeGen, or another build process. Use the existing approach; do not introduce a new build system just for the icon.
2. Install the blue rounded-square Files icon, depicting a folder and a two-pane file explorer, as the macOS application's primary icon.
3. If the project uses an Xcode asset catalog, merge `Assets.xcassets/AppIcon.appiconset` and configure the app target to use the `AppIcon` set. Preserve other assets.
4. If the project manually creates `Files.app`, include `FilesIcon.icns` in `Contents/Resources/` and set `CFBundleIconFile` to `FilesIcon` in `Contents/Info.plist`.
5. Update `./build.sh` so clean builds automatically package the icon. Update `./install.sh` only as needed to ensure the built `.app` is installed with the icon. Keep both scripts usable at the repository root.
6. If code signing is used, package the icon **before** signing; do not alter a signed bundle afterward.
7. Use repository-relative paths, and add the necessary icon files to version control. Keep the smallest practical set of sources and generated files for the project's build model.
8. Run any available build checks, verify the `.app` bundle or asset catalog, and report file changes and how to validate the icon in Finder and Dock.
9. Do not alter file-browser behavior, unrelated build settings, bundle identifiers, or existing app functionality.

Available files from this archive:
- `FilesIcon.png` (1024px transparent master)
- `FilesIcon.icns` (ready-to-use)
- `FilesIcon.iconset/` (Apple iconutil source)
- The `AppIcon` Xcode asset set is integrated in the app at `Files/Assets.xcassets`.
- `scripts/` (helper scripts)

Choose the right integration route based on the repository, rather than blindly using both.
