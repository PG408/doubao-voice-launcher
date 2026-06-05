# Doubao Voice Input Switcher

Doubao Voice Input Switcher is a macOS helper tool that temporarily switches to the Doubao input method during voice input and restores the original input method after voice input ends. This project is an unofficial tool and is not released by Doubao or ByteDance.

This is a pure Codex vibe-coding project: requirements, implementation, packaging scripts, and documentation were all generated and iterated by the user through interactive Codex sessions.

## Features

- Supports both press-and-hold and single-click trigger modes.
- Temporarily switches to the Doubao input method when voice input starts, then restores the original input method when it ends.
- Supports selecting shortcuts for each mode inside the app; modes without a selected shortcut will not be triggered.
- Supports configuring the forwarding delay and the press-and-hold trigger duration.
- Supports checking the Doubao input method installation status, current input source, and background listener status.
- Provides quick entries for Accessibility settings and Doubao settings.
- Provides local debug logs to help troubleshoot shortcuts, input method switching, and voice startup confirmation.

## Requirements

- macOS 13 or later.
- Doubao input method installed.
- Accessibility permission must be granted on first use.

Current release packages are usually built locally with SwiftPM, so the architecture depends on the build machine. The default artifact built on an Apple Silicon machine is arm64. To support Intel Macs at the same time, an additional universal binary must be created.

## Installation

1. Download `DoubaoVoiceLauncher.zip` from GitHub Releases.
2. Unzip it, then drag `豆包语音输入切换.app` into the Applications folder.
3. On first launch, if macOS shows a "cannot verify the developer" warning, right-click the app and choose "Open", or allow it in System Settings - Privacy & Security.
4. Enable Accessibility permission as prompted by the app. If authorization still does not take effect, quit and reopen the app.

## Usage

Usage steps:
- Set the voice input shortcut in the Doubao input method.
- Open the app and grant Accessibility permission.
- Restart the app, then set the "Press-and-hold mode" or "Single-click mode" shortcut in the app as needed, using the same shortcut as Doubao voice input.
- Adjust timing settings as needed:
  - Forwarding delay: the delay before triggering the shortcut after switching to the Doubao input method.
  - Press-and-hold trigger duration: how long the shortcut must be held before it is recognized as a press-and-hold action.
- Start using the app:
  - Press-and-hold mode is for "hold to talk, release to end". The app temporarily switches to the Doubao input method while the shortcut is held, then restores the original input method after release.
  - Single-click mode is for "click once to start, click again to end". After the first shortcut click, the app temporarily switches to the Doubao input method and keeps the Doubao voice shortcut held on the user's behalf. After the same shortcut is clicked again, the app releases the shortcut and restores the original input method.

The app only listens for shortcut combinations selected by the user and switches input methods through local macOS input source APIs.

## Startup Confirmation Mechanism for No-Hold Mode

Single-click mode is a no-hold mode: the app keeps the Doubao voice shortcut held on the user's behalf until the user triggers the end action again. Because completion of macOS input method switching does not mean Doubao's internal voice pipeline is ready, the app uses the following startup flow in no-hold mode:

1. Switch to the Doubao input method and confirm that the current input source has changed to Doubao.
2. Immediately send a `keyUp` for the same shortcut to Doubao to clear any possibly residual modifier-key state.
3. Wait for the forwarding delay configured by the user in the app.
4. Send the first `keyDown` to start attempting to launch Doubao voice input.
5. Check whether the Doubao input method is running an audio input stream at the cumulative time points `350ms`, `600ms`, and `750ms`.
6. Once any checkpoint confirms success, the app enters the voice-input hold state.
7. If all three checks fail, the app sends `keyUp`, waits `100ms`, then sends a second `keyDown` to retry once.
8. If the second attempt still cannot be confirmed, the app releases the shortcut and restores the original input method so the user can trigger it again.

This mechanism applies only to single-click no-hold mode. It does not change the press-and-hold mode semantics of "hold to talk, release to end".

## Local Build

This project is built with Swift Package Manager:

`./script/build_and_run.sh --no-run`

This command generates:

- `dist/豆包语音输入切换.app`

To generate a compressed package that can be uploaded to a GitHub Release:

`./script/build_and_run.sh --package`

This command generates:

- `dist/豆包语音输入切换.app`
- `dist/DoubaoVoiceLauncher.zip`

The default build configuration is debug, which preserves the runtime behavior of synthesized shortcut events used by the currently available package. To temporarily use a release build, run:

`BUILD_CONFIGURATION=release ./script/build_and_run.sh --no-run`

## Debug Logs

The app automatically saves key debug information to:

`~/Library/Logs/DoubaoVoiceLauncher/DoubaoVoiceLauncher.log`

At the same time, the app still uses `com.local.doubao.voice-launcher` as the macOS unified logging subsystem and records key runtime events under the categories `App`, `UI`, `Permissions`, `Automation`, `Shortcut`, and `InputSource`.

When troubleshooting no-hold mode startup issues, check the following log fragments first:

- `No-hold activation preflight reset keyUp sent`: indicates that a preflight `keyUp` reset has been sent after input method confirmation.
- `No-hold activation pending after forwarded keyDown`: indicates that a `keyDown` has been sent for a startup attempt.
- `No-hold activation probe 1/3`, `2/3`, `3/3`: indicate the startup confirmation checks at `350ms / 600ms / 750ms`.
- `No-hold activation attempt 1 failed`: indicates that the first three-stage check did not confirm success, so the app will release the shortcut and retry once.
- `No-hold activation confirmed`: indicates that the Doubao input method has been detected running an audio input stream.

To launch the app and view the automatically saved file log:

`./script/build_and_run.sh --tail-file-log`

To launch the app and view telemetry for this app:

`./script/build_and_run.sh --telemetry`

To view broader runtime logs by process if needed, run:

`./script/build_and_run.sh --logs`

## Signing and Security Notes

The current script uses ad-hoc signing, which is suitable for personal or small-scale trial use. For public distribution, macOS may warn that the developer cannot be verified. For releases intended for a broader user base, signing with an Apple Developer ID certificate and completing Apple notarization are recommended.

The current source code contains no network request logic. The tool's core capabilities are local shortcut listening and input method switching. Users can audit the source code to confirm its behavior.

## Disclaimer

This project is a personal helper tool. Users should independently confirm that it complies with their organization's software installation, security, and privacy policies.
