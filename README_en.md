# Extra Viewer

[简体中文](README.md) | [English](README_en.md)

> An Android-first local library for browsing large collections from folders, removable storage, and offline media sources.

Extra Viewer turns scattered files into a browsable personal library without taking ownership of the originals. It keeps source folders read-only, separates physical location from personal organization, and lets you browse the same files through three complementary index types.

## What makes it different

Most file browsers force one structure to do several jobs. Extra Viewer keeps those jobs separate:

| Index | Answers | How it works |
| --- | --- | --- |
| **Directory** | Where is the file physically stored? | Mirrors the real folder tree and remains connected to the source directory. |
| **Category** | How do I want to organize it? | Stores references to files and folders without copying or moving originals. |
| **Rule** | Which files matter right now? | Computes a live result set from conditions such as type, location, time, size, and usage. |

This separation is the central design of Extra Viewer. A file can remain in its original directory, appear in several categories, and also appear in dynamic rules. These views do not compete with one another and do not create duplicate physical files.

## The three-index model

### 1. Directory index: preserve reality

Choose a folder through Android's system file picker. Extra Viewer scans the selected directory and keeps its hierarchy as the source of truth.

- Original files stay in place and are never renamed, moved, or deleted.
- Subfolders remain navigable as real folders rather than imported labels.
- Incremental updates can be run for a source or a folder.
- The app can continue displaying saved library data when a removable source is temporarily offline.
- Returning from a file opened through a category or rule can jump to its actual directory folder.

The directory index is for reliable location and source management. It is not mixed with personal tags or temporary queries.

### 2. Category index: organize without duplication

Categories are a separate organization layer built from references. Add files to multiple categories, create nested groups, and arrange material around a project, subject, or workflow.

- One file can belong to multiple categories.
- Categories do not copy, move, or rewrite source files.
- The protected **收藏** category is available for files you want to keep close.
- Category covers and local ordering are independent from the physical source tree.
- Removing a category relationship does not delete the original file.

The category index is intentionally manual. It represents your decisions, not an automatic guess made from file names.

### 3. Rule index: dynamic views instead of duplicate collections

Rules are virtual indexes. They do not write result references into a second collection table; they query the existing library data when opened.

Built-in rules include:

- 常用
- 最近图片
- 最近视频
- 最近文本
- 最近音乐

Custom rules can combine file type, extension, directory or category scope, size, modification time, and recent-open time. Conditions across fields use `AND`; multiple values inside one field use `OR`.

This gives rules three practical advantages:

1. **Always current**: opening a rule reflects the latest library state and access history.
2. **No duplicate references**: a matching file is not copied into a rule-specific result table.
3. **No rebuild step**: changing a rule changes the next query, not a background indexing job.

The **常用** rule uses access count and last-opened time. Opening a file increments its usage atomically, so frequently used material naturally rises to the top.

## Browse the way you want

The top floating **浏览选项** panel controls the current browsing experience:

- Sort by recent modification, name, or size.
- Switch between cards and lists.
- Card styles: equal height, equal width, or square.
- List styles: text-only, compact, or normal.
- Select the theme: system, light, or dark.
- Select the layout density: compact, standard, or spacious.
- Select folder covers: automatic, square, or stacked.

Automatic folder covers use square compositions in portrait orientation and stacked covers in landscape orientation. In portrait mode, folder grids use 4 columns for compact, 3 for standard, and 2 for spacious. The chosen browsing preferences are saved locally.

Other browsing behavior is designed for repeated use:

- Directory and category pages remember their separate folder and scroll position during the current app session.
- Rule pages remember the active rule while moving between top-level sections.
- Immersive browsing expands the visible content without losing an exit control.
- Long press or the selection button opens the same multi-selection toolbar.
- The floating glass controls stay above content and respect safe areas on phones and tablets.

## Built-in viewing

Extra Viewer opens common images, videos, audio files, PDFs, EPUBs, and text documents inside the app.

- Images and videos use a shared bottom control surface.
- The mini audio player remains available above media viewers when appropriate.
- Reading positions are saved using document-aware anchors where available.
- Playback position and duration are saved for audio and video.
- Folder previews can use generated local assets, with an empty-folder fallback when no content is available.
- Missing previews can be retried without hiding the file from the library.

## Designed for large local libraries

The application is a modular Flutter/Dart monolith with a strict database boundary:

```text
Android SAF / local source
          |
          | read-only access
          v
     Directory index ---- physical location
          |
          +---- Category index ---- manual references
          |
          +---- Rule index -------- live queries
          |
          +---- Preview assets, reading state, playback state
```

The storage and browsing design is optimized around predictable work:

- SQLite is owned by a single write worker, preventing competing business writes.
- Read queries run through a separate read worker so UI code does not hold database connections.
- Browsing uses paged queries and stable cursors instead of loading an entire library into memory.
- Long scans persist scope, directory queues, item status, progress, and retry state.
- A pause stops new work at a commit boundary; abandoning a task keeps already committed files.
- Partial source failures are recorded as failures and do not become evidence that files should be deleted.
- Preview files are published atomically and old assets are cleaned up later.
- Thumbnail decoding, source-file staging, and offline preview storage have separate lifecycles.

This architecture keeps the three index types useful at different scales: the directory index provides source fidelity, categories provide human control, and rules provide fast-changing views without multiplying stored relationships.

## Data and privacy

Extra Viewer is local-first.

- Source files remain read-only.
- Android folder access uses the system Storage Access Framework (SAF).
- The app does not upload your files or require a cloud account.
- Database records, thumbnails, previews, and playback state are stored in the app's private data area.
- A scan can be paused, resumed, retried, or abandoned without deleting successfully committed library data.
- Clearing app-owned data is separate from deleting source files; the app never treats a source folder as writable storage.

## Download and install

Extra Viewer currently targets Android arm64 devices, including phones and tablets.

Download the latest APK from [GitHub Releases](https://github.com/lzhuofei24/extra-viewer/releases) when a release asset is available. The expected arm64 artifact is:

```text
extra-viewer-1.0.0-arm64.apk
```

Allow installation from the source you used to download the APK, then open Extra Viewer and grant access to the directories you want to browse. The app does not need permission to modify those directories.

## Build from source

Development requires:

- Flutter SDK
- Android SDK and NDK
- JDK 21
- Accepted Android SDK licenses
- A configured Extra Viewer release signing file for release builds

Run the regular checks:

```powershell
flutter pub get
flutter analyze
flutter test
```

Build signed Android artifacts with:

```powershell
.\tools\build-android-release.ps1
```

The build script produces an arm64 APK, an all-ABI AAB, and SHA-256 checksums under `dist/`. Release builds fail when the configured release key is missing; they never silently fall back to a debug certificate.

## Repository layout

```text
lib/src/core/          database, source access, media and preview foundations
lib/src/modules/       library, build, preview and viewer boundaries
lib/src/ui/             browsing, rules, management and shared glass UI
android/                Android SAF and native media integrations
assets/                 application assets
docs/                   architecture and historical engineering notes
tools/                  release and maintenance scripts
test/                   database, worker, recovery and UI tests
```

The Android app is intentionally the maintained product target. Desktop and iOS builds are not release targets at this time.

## Project status

Extra Viewer is an Android-focused personal-library project under active development. The stable product direction is local browsing through directory, category, and rule indexes. Search is limited to index names and does not search entity names, file paths, document bodies, or cloud content.

Bug reports are most useful when they include the Android version, device model, source type (local folder, TF card, or removable drive), and the relevant diagnostic details. Please do not upload private media when reporting an issue.

## License

License and third-party attribution details will be added before the first public distribution release.
