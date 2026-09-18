# Extra Viewer Agent Guide

## Repository

- The active Git and Flutter project root is `D:\project\learn-myself\best-viewer\app`.
- Run Git, Flutter, Dart, Gradle, and ADB commands from this directory.
- The product is Android-only. Do not restore or add Windows application support unless the user explicitly requests it.
- Keep original user files read-only. Generated databases, previews, and caches belong to the app.

## Toolchain

- Flutter: `D:\program\dev\flutter\bin\flutter.bat`
- Dart: `D:\program\dev\flutter\bin\dart.bat`
- Android SDK: `%LOCALAPPDATA%\Android\Sdk`
- ADB: `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`
- Default Java: `C:\Program Files\Java\jdk-21`

Do not infer a build failure from stale terminal output. Read the current process result and the generated file timestamp.

## Required Validation

For ordinary Dart or Flutter changes, run in this order:

```powershell
D:\program\dev\flutter\bin\dart.bat format <changed dart files>
D:\program\dev\flutter\bin\flutter.bat analyze
D:\program\dev\flutter\bin\flutter.bat test
```

Use focused tests while iterating, but run the complete test suite before the final commit. Do not run formatters on unrelated files.

## Release APK Build

Java on this machine can fail before Gradle compilation with:

```text
java.io.IOException: Unable to establish loopback connection
```

This is caused by Java `PipeImpl` using the default Unix-domain temporary location. It is not a Dart compile error, proxy failure, or necessarily a broken JDK. Always create an ASCII temporary directory and set `jdk.net.unixdomain.tmpdir` for Android builds:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-21'
$javaTemp = Join-Path (Get-Location) 'build\java-tmp'
New-Item -ItemType Directory -Force -Path $javaTemp | Out-Null
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$($javaTemp.Replace('\', '/'))"
D:\program\dev\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi --no-pub
```

Expected artifact:

```text
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

After building, verify the command exited successfully and the APK timestamp is newer than the build start. Never report, distribute, or install an older APK after a failed build.

## Device Installation

After a successful update, check for a connected Android device:

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices -l
```

If a device is authorized, install the newly built APK without clearing application data:

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install -r "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
```

If no device is listed, do not claim installation succeeded. Report the APK path and wait for a device connection.

## Git And Delivery

- Preserve unrelated user changes in a dirty worktree.
- Use `apply_patch` for manual source edits.
- Create a local commit after the requested change passes validation.
- Do not push unless the user explicitly requests it.
- Do not amend existing commits unless explicitly requested.
- Before committing, run `git diff --check` and confirm the staged file list contains only intended changes.

## Product Constraints

- Keep the application database behind its existing worker and module interfaces; UI code must not access SQLite directly.
- Preserve persistent preview publication semantics: write immutable files first, conditionally publish references, and retire old files later.
- Do not reintroduce graph indexes, desktop application code, index package import/export, or the pet system.
- Prefer localized updates and existing project abstractions over adding parallel state or rebuild paths.
- The current navigation and user terminology are `目录`, `分类`, `最近`, `管理`, and `设置`.
