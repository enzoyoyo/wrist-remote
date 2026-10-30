# Watch control center

[中文](../zh-CN/control-center.md)

Pair the iPhone with the Mac Bridge and open the Watch control center. Select the target and mode on the Watch. Mac control requires Accessibility permission. Actions expire and are not replayed after an interrupted connection.

## Controls

The touchpad moves and clicks the Mac pointer; its secondary button performs a right click and the crown scrolls. Media controls provide playback, track and volume actions. Presentation mode sends page and presentation controls to the foreground Mac app. Custom remote mappings remain available in More.

## Audio

Watch audio requires the iPhone relay even when direct Mac control is available. Foreground dictation, local recording, and virtual microphone output are separate modes. Recording writes mono 16 kHz, 16 kbps AAC to M4A on the Mac. Wait for the Mac outcome before treating a recording as saved. Recording and microphone output stop at 115 seconds, on connection loss, or on excessive backlog; interrupted recordings are not resumed automatically.

For microphone output, select an available virtual output device in the Mac app and select the same device as the input in the target app. The system default input and output are not changed. BlackHole 2ch is intentionally refused to protect an existing audio route. Actual audio, latency, and background behavior require real-device validation.

The separate Codex live-dictation mode is unfinished and disabled in this release. It would require an independent duplex virtual device. It sends a configurable toggle shortcut but cannot confirm whether Codex started or stopped listening; its complete audio and text path has not been validated. Changing the Codex microphone also affects its existing Fn dictation. Check and restore the Codex input device as needed. No text is submitted automatically by this mode.

## Television and reading

For an Android / Google TV, configure the actual local address and a local adb executable in the Mac app. Approve any required authorization on the television. The adapter only sends fixed navigation, playback, and volume keys. Apple TV is not supported by this adapter.

For reading, open Wrist Remote on the iPhone or iPad, pair it with the same Mac, import or paste UTF-8 text, and start a reading session. Select that session on Watch to change paragraphs, pause, and adjust speed. Mirrored and landscape reading are available. This controls the app's own session, not arbitrary iPad apps.

Simulator results do not establish physical-device audio, haptics, background operation, or external-device behavior.
