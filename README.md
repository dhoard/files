# Files

A small, native macOS file manager with a Windows File Explorer-style layout and
an always-editable GNOME Files-style location bar. It is written in Swift using
AppKit only (no SwiftUI, no web views, no nibs) and built with `xcodebuild`.

Current version: **0.1.0**.

Each window contains:

- a lazily populated directory tree on the left (filesystem root plus mounted
  volumes under `/Volumes`),
- a detailed listing on the right (Name, Date Modified, Type, Size),
- an always-editable absolute POSIX path field with Back / Forward / Up / Refresh.

There are no tabs. `⌘N` opens a second independent window with its own history,
selection, sort and expansion state.

## Requirements

- macOS 14 or later on Apple Silicon (arm64)
- A full Xcode installation with command line tools selected
  (`sudo xcode-select -s /Applications/Xcode.app`)
- The app is built unsigned for local development (`CODE_SIGNING_ALLOWED=NO`);
  the sandbox is off. OS privacy controls still apply, and Files never attempts
  to bypass them.

The application name and bundle are **Files** (executable `Files`, app
`Files.app`). The Xcode project, targets and shared scheme use the same name,
the bundle identifier is `com.files.app`, and preference keys use the `files.*`
prefix.

## Build, test, install, launch

```bash
./build.sh                 # Release build, stages dist/.build/Files.app
./install.sh               # installs dist/.build/Files.app to /Applications/Files.app
open /Applications/Files.app
```

`./build.sh` uses a project-local, hidden derived-data directory
(`dist/.derivedData`), produces an arm64 executable, validates it with `lipo`,
and prints `dist/.build/Files.app`. It never installs or runs the app. Both
scripts can be run from any working directory, including paths containing
spaces.

The build output is deliberately hidden (`dist/.build`, `dist/.derivedData`),
following the pattern used by [`../quadrant`](../quadrant): Spotlight does not
index hidden items, and Spotlight's application index is what the macOS launcher
lists. A bundle built in a visible directory shows up as another Files beside
the installed one. `build.sh` also unregisters build products from LaunchServices
and removes stale visible `build/Files.app` output from older versions; only
`./install.sh` puts a launcher-visible copy in `/Applications`. Run the
installed copy rather than opening `dist/.build/Files.app`; opening a build
bundle in Finder registers it with LaunchServices and can add another launcher
entry. Likewise, raw `xcodebuild` builds that use the default DerivedData path
can produce a launcher-visible copy, so use `./build.sh` or pass a hidden
`-derivedDataPath`.

Run `./install.sh` with `sudo` when you want the system-wide icon cache cleared
(recommended after an icon change; `sudo` is also used when `/Applications` is
not writable). Without `sudo`, the installer still clears user caches and
restarts Dock, but cannot clear `/Library/Caches/com.apple.iconservices.store`.

`./install.sh` requires an existing `dist/.build/Files.app`; it never builds. It stages
a complete bundle inside `/Applications`, validates it, moves the previously
installed bundle aside, and rolls back on failure. It refuses to replace a
running copy, does not launch the app, and does not touch preferences. After a
successful install it clears the icon/launcher caches, re-indexes the bundle for
the invoking user (when run with `sudo`), and restarts the Dock and Apps
launcher so the new icon is used. A previously installed `/Applications/Files.app`
is moved aside during the install and restored if the replacement fails. The
installer registers only `/Applications/Files.app`, so Spotlight and Launchpad
list one application. If `/Applications` is not writable it prints instructions
for running it with `sudo`; it never assumes non-interactive `sudo`.

Tests:

```bash
xcodebuild \
  -project Files.xcodeproj \
  -scheme Files \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath dist/.derivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The shared scheme `Files` runs the hostless `FilesTests` XCTest bundle; tests do
not need (and the scheme does not build) the application, and the hidden
derived-data path keeps test products out of Spotlight and the launcher. Tests
use temporary directories and private pasteboards; they do not touch user files
or the general clipboard.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| `⌘N` | New independent window |
| `⌘W` | Close the active window |
| `⌘L` | Focus the location field and select all |
| `⌘[` / `⌘]` | Back / Forward |
| `⌘↑` | Enclosing folder |
| `⌘C` / `⌘X` / `⌘V` | Copy / Cut / Paste selected files |
| `⌘A` | Select all in the focused listing/tree |
| `⌘Delete` | Move selection to Trash |
| `⇧⌘N` | New folder (then inline rename) |
| `F2` | Rename selected item |
| `⌘R` | Refresh |
| `⌘O` | Open selected item |
| `⇧⌘R` | Reveal in Finder |
| `⌘I` | Get Info |
| `⇧⌘H` | Show/hide hidden files |

While the location field or the inline rename field has focus, the standard text
editing commands (`⌘A`, `⌘C`, `⌘V`, etc.) go to the text editor; file commands
apply when the tree or file listing has focus.

`F2` uses the function key directly. If macOS is configured to use F1–F12 as
standard function keys (System Settings → Keyboard), the key may be intercepted
by the system; the File menu and the context menu always provide Rename.

## Navigation and paths

- The location bar always shows an editable absolute path (never a breadcrumb).
  Return navigates only if the path is an existing, readable directory.
  Escape restores the current path. `~` and `~/…` (and `~user`) expand.
  Tab completes a single matching name (appending `/` for folders) or extends
  multiple matches to their common prefix.
- Invalid or inaccessible paths display an inline error and leave the current
  directory unchanged.
- Paths are lexical: Files standardizes `.`/`..` and slashes but does **not**
  resolve symbolic links, so the location bar shows the path you navigated to.
  A directory symlink is shown as a folder and can be entered; copying a symlink
  copies the link itself (never its target), so copy loops cannot occur. Tree
  expansion refuses links that resolve to an ancestor and caps expansion depth.
- History never records duplicate entries for the same path, and Back/Forward
  validate the destination before moving, so a deleted history entry cannot
  change the window.

## Listing behavior

- Folders sort before files, ascending or descending, then by the selected
  column using localized natural ordering. Default sort is Name ascending.
- Kind/type comes from filesystem metadata (`localizedTypeDescription`), not just
  the filename extension.
- Hidden files are hidden by default; the preference is persisted.
- Application bundles and other packages are shown as documents and open with
  the default application rather than being entered. The tree omits packages.
- Double-click (or Return/`⌘O`) opens a file with its default application and
  enters a folder. Selection and scroll position are restored across refreshes.
- Directory reads and metadata collection happen on a background queue; large
  directories do not block the main thread.

## File operations and safety

Every entry point (menus, keyboard, context menus, drag/drop, clipboard) calls
the same `FileOperations` service:

- **Copy / Cut / Paste** support multiple items.
- **Rename** uses inline editing with the base name selected (extension
  excluded); collisions are rejected.
- **New Folder** creates a uniquely named folder and immediately starts inline
  rename.
- **Move to Trash** uses the native Trash (`FileManager.trashItem`). Files never
  performs permanent deletion as an explicit user command.
- **Open With**, **Reveal in Finder** and **Get Info** are available from the
  context and File menus. Get Info is Files' own native info sheet, because
  macOS offers no public API for opening Finder's Info window.
- Folder copy/move into itself or one of its descendants, self-copies, moves to
  the current folder, and same-item conflicts are detected before mutation
  using filesystem identity (and case-aware path comparison for volumes that
  are case-insensitive).
- On conflict the user chooses **Replace**, **Skip**, or **Cancel** (optionally
  applying the choice to remaining conflicts). Destinations are never
  overwritten in place: the existing item is moved to a temporary sibling,
  the new item is put in place, and only then is the old item deleted. If the
  transfer fails or is cancelled, the old item is restored and partial output
  is removed.
- Long copy/move operations run off the main thread with a progress panel and a
  Cancel button. Cancellation stops between files/directories (not mid-file),
  and the result reports exactly which items completed, were skipped, or failed.
- Cross-volume moves copy first, verify the copy structurally (names, regular
  file byte sizes, symlink targets — no checksums), and only then remove the
  source. If verification or source removal fails the source is kept and the
  failure is reported. Sources are never removed before the copy succeeds.
- Read-only volumes, permission errors, disappearing sources and other I/O
  errors are reported; Files does not bypass macOS permissions or privacy
  controls.
- If restoring a staged replacement itself fails (for example the volume becomes
  read-only mid-operation), the previous item is kept in the destination folder
  under a hidden `.files-replace-<UUID>` name rather than being deleted; it can
  be recovered with Finder or Files (enable hidden files).

### Clipboard, cut intent, and Finder

Copy writes standard `public.file-url` pasteboard items (plus the legacy
`NSFilenamesPboardType` list) so other applications can read them. Cut writes the
same file URLs plus `com.files.cut-file-urls` (a JSON path list) on the
pasteboard. Cut intent therefore travels between independent Files windows
without process-local state and disappears automatically if another application
replaces the clipboard. Cut rows are dimmed. After a successful cut/paste the
clipboard is cleared; after a partial one it is rewritten with the sources that
still exist. Files does **not** claim Finder `⌘X` interoperability: Finder's cut
semantics differ, and only copy/paste plus drag/drop with Finder were considered
compatible.

## Drag and drop

Dragging uses standard file-URL pasteboard items:

- list → list, list → tree folder, tree → other window, and Files ↔ Finder.
- Dropping on a folder row targets that folder; dropping on the listing
  background (or a non-folder row) targets the current folder.
- Same volume defaults to **Move**; cross volumes default to **Copy**.
  Hold **Option** to copy and **Command** to move.
- The drag source's advertised operation mask wins. If the requested operation
  is not offered, Files falls back to the offered one or refuses the drop.
- Dropping onto the same file, the same folder, or a source's descendant is
  rejected, as are tree between-row drops and drops on the tree background.
  File operations are executed through `FileOperations`, not ad-hoc code.

## Preferences

Stored in `UserDefaults` (no database, no preferences window):

- window frame/position (`files.windowFrame`)
- splitter fraction (`files.splitFraction`)
- sort column and direction (`files.sortKey`, `files.sortAscending`)
- column widths (`files.columnWidth.<column>`)
- hidden-file visibility (`files.showHiddenFiles`)

Preferences live in the application's `com.files.app` domain. `install.sh`
never deletes preferences, and the app never deletes or rewrites them outside
normal preference updates.

## Application icon

The app icon is the blue rounded-square split-pane mark supplied in
`FilesIcon/`. The Xcode `AppIcon` asset set is integrated in the app source at
`Files/Assets.xcassets/AppIcon.appiconset`; the app target uses
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, so the build emits
`Contents/Resources/Assets.car` and `AppIcon.icns` and sets `CFBundleIconFile`
and `CFBundleIconName` to `AppIcon`. No loose icon file or external icon
directory is required to build.

`FilesIcon/` retains the 1024 px master, the `.icns`, the `.iconset` and the
regeneration script for future artwork changes; it is not a build dependency.
`FilesIcon/scripts/regenerate-icns.sh` regenerates the standalone `.icns` from
the iconset if the artwork is edited.

macOS caches application icons. `./install.sh` now clears the user icon caches
and restarts Dock/Apps automatically; when run with `sudo` it also clears the
system cache and restarts the icon services. No manual cache step is normally
needed after an install.

If an old icon still survives (for example after an install without `sudo`, or
because a launcher process kept a memory cache), run the installer again with
sudo, or manually:

```bash
sudo rm -rf /Library/Caches/com.apple.iconservices.store
killall iconservicesagent
killall Dock
```

Reopen the application launcher afterward. The app bundle itself should contain
`Contents/Resources/Assets.car` and `Contents/Resources/AppIcon.icns`, with
`CFBundleIconFile`/`CFBundleIconName` set to `AppIcon`.

## Live updates

FSEvents watches only the open directory and expanded tree branches. Event
bursts are debounced (about 250 ms), only affected directories are invalidated,
and unrelated expanded branches, selection and scroll position are preserved.
Deleting/renaming the current directory moves the window to the nearest existing
ancestor. Volume mount/unmount/rename notifications refresh the tree root.

## Source layout

```text
files/                          # repository root
├── build.sh, install.sh
├── dist/                       # ignored build output
│   ├── .gitkeep
│   ├── .build/Files.app        # hidden Release bundle (not indexed)
│   └── .derivedData/           # hidden Xcode derived data
├── Files.xcodeproj/            # app target + hostless XCTest target, shared scheme
├── Files/
│   ├── Assets.xcassets/        # AppIcon asset set (compiled into Assets.car)
│   ├── main.swift              # NSApplication event loop
│   ├── AppDelegate.swift       # app lifecycle + programmatic menus
│   ├── ExplorerWindowController.swift  # per-window state, actions, layout views
│   ├── NavigationController.swift      # history, path resolution, volume identity
│   ├── DirectoryTreeController.swift   # lazy tree
│   ├── FileListController.swift        # listing, sorting, inline rename, drops
│   ├── PathBarController.swift         # editable location field
│   ├── FileOperations.swift            # central copy/move/rename/trash service
│   ├── ClipboardService.swift          # file URLs + cut marker
│   ├── DragDropCoordinator.swift       # drag/drop policy and validation
│   ├── DirectoryMonitor.swift          # FSEvents monitoring
│   ├── FileSystemItem.swift            # listing model, metadata, sorting
│   ├── Preferences.swift               # UserDefaults
│   ├── InfoSheetController.swift       # Get Info sheet
│   └── OperationProgressPanel.swift    # progress/cancel panel
├── FilesTests/                 # 95 XCTest cases
├── FilesIcon/                  # icon master/ICNS/iconset + regeneration scripts (not a build dependency)
└── README.md
```

## Known limitations

- Finder cut/paste interoperability and drag/drop *to and from Finder* have not
  been exercised by automated tests (they require interactive sessions). Standard
  file-URL pasteboard representations are used.
- Cross-volume move verification (copy → structural check → remove source) is
  implemented but could not be exercised in this environment because no second
  writable volume was available. Extra volumes appear in the tree and are
  handled by the same code path.
- macOS privacy controls (Desktop/Documents/Downloads/removable volumes) may
  present a consent prompt and can deny access; the app reports the resulting
  errors instead of bypassing them.
- Tree children are enumerated synchronously when a node is first displayed or
  expanded. Only directories are enumerated, children are cached, and nothing is
  enumerated recursively, but a very large directory on a slow/network volume can
  briefly delay that expansion.
- Renaming a directory from the tree navigates the listing to its parent first,
  because inline rename happens in the detailed listing.
- Packages are treated as documents in listings and omitted from the tree.
  Get Info shows them as "Folder" (metadata view), and folder size is not
  computed recursively.
- Replacing a conflicting destination replaces it as a whole; directory trees
  are not merged (Windows Explorer-style merge prompts are not implemented).
- There is no search, no preview pane, and no tabs, by design.
- The app is unsigned for local use; a distribution build would need signing and
  notarization.

## Manual acceptance walkthrough

See the plan/README checklist items; automated coverage includes navigation
history, independent windows, listing/layout structure, path validation,
clipboard formats and cut intent, drag/drop policy, FSEvents updates, file
operations (copy/move/rename/conflict skip-replace-cancel, symlinks, Unicode,
cancellation, trash), preferences and menu wiring. Interactive drag/drop,
Finder interoperability, cross-volume moves and privacy prompts remain manual.
