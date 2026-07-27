<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="sotto" width="300">
  </picture>
</p>

> Private, on-device call recording and transcription for macOS.
> No cloud. No accounts. No virtual audio drivers.

Sotto lives in your menu bar. Hit record before a call, hit stop after —
it captures **both sides** of the conversation (your mic + system audio),
transcribes everything **locally** with Whisper, and gives you a timestamped,
exportable transcript. Nothing ever leaves your machine.

**Status: beta1 (`v0.1.0-beta.1`).** The core recording and transcription
pipeline works; rough edges remain. Issues and PRs are welcome.

## Download

[**Download the latest Sotto beta (.zip)**](https://github.com/nikitapogorelov/sotto/releases/latest/download/Sotto.zip)

The release archive is a universal macOS build for Apple Silicon and Intel.
The Whisper model is not bundled; Sotto downloads the model you choose on
first launch.

1. Unzip `Sotto.zip` and move `Sotto.app` to `/Applications`.
2. Control-click Sotto and choose **Open**. If macOS still blocks it, try
   opening it once, then go to **System Settings → Privacy & Security** and
   click **Open Anyway**.
3. Grant **Microphone** and **Screen & System Audio Recording** when prompted.

> Beta1 is ad-hoc signed and is not notarized by Apple, which is why the first
> launch needs explicit approval. You never need to disable Gatekeeper.

## Features

- **Records both sides without a virtual audio driver.** ScreenCaptureKit
  captures system audio while AVAudioEngine records your microphone.
- **Transcribes locally with Whisper.** Audio and transcripts stay on your
  Mac; there are no accounts and no transcription cloud.
- **Shows a live draft during the call.** A final full-quality pass replaces
  it automatically after recording stops.
- **Labels the two sides as Me / Them.** Separate mic and system channels give
  Sotto useful baseline speaker diarization and correctly ordered timestamps.
- **Detects calls without auto-recording.** Native call apps and supported
  browsers can trigger a notification offering a one-click start.
- **Exports timestamped Markdown.** Copy a transcript, save it as `.md`, or
  re-transcribe an old recording with another installed model.
- **Stays out of the way.** Recording controls live in the menu bar, with an
  optional global start/stop hotkey.

## Why

Every call-transcription tool on the market either uploads your audio to
someone's cloud or requires installing a virtual audio driver (BlackHole,
Loopback) and wiring up Multi-Output devices by hand. Sotto does neither:

- **System audio via ScreenCaptureKit.** Since macOS 13, SCK can capture
  system audio output natively. Sotto uses it to record the remote side of
  your call with zero audio-routing setup.
- **Transcription via whisper.cpp.** Runs on-device through Metal on Apple
  Silicon. `large-v3-turbo` handles mixed-language calls (e.g. Russian +
  English) well and transcribes a 30-minute call in a couple of minutes.
- **Your data stays yours.** Recordings and transcripts live in
  `~/Library/Application Support/Sotto/`. The only network request the app
  ever makes is the one-time model download from Hugging Face.

## Architecture

```
                        ┌──────────────────────┐
  system audio ────────►│ SystemAudioTap       │──┐
  (remote side,         │ (ScreenCaptureKit)   │  │  16 kHz mono Float32
   no BlackHole)        └──────────────────────┘  │
                                                  ├──► stereo WAV (L=mic, R=system)
                        ┌──────────────────────┐  │             │
  microphone ──────────►│ MicTap               │──┘             ▼  per channel
  (your side)           │ (AVAudioEngine)      │       ┌────────────────────┐
                        └──────────────────────┘       │ WhisperTranscriber │
                                                       │ (whisper.cpp,      │
                        ┌──────────────────────┐       │  Metal, on-device) │
  UI ◄──── SwiftUI ────►│ RecordingController  │◄──────┴────────────────────┘
  MenuBarExtra +        │ RecordingStore       │   Me/Them-labeled segments,
  Transcripts window    │ (JSON + files)       │   merged by timestamp
                        └──────────────────────┘
```

## Requirements

- macOS 14.2 (Sonoma) or later — call detection attributes microphone use to a
  specific process via the per-process audio objects added in 14.2
- Apple Silicon recommended (Whisper runs via Metal; Intel works but slowly)
- Xcode 15+ / Swift 5.9+
- ~2 GB free disk for the Whisper model

## Build & run

```bash
git clone https://github.com/nikitapogorelov/sotto.git
cd sotto
./scripts/bundle.sh        # swift build -c release + wraps into Sotto.app
mv Sotto.app /Applications
open /Applications/Sotto.app
```

> Why the bundle script? TCC permissions (Microphone, Screen Recording)
> attach to an app bundle with a stable identifier — a bare SPM executable
> would re-prompt on every rebuild.

Unit tests: `./scripts/test.sh` (equivalent to `swift test`, but also works
with Command Line Tools alone, where the swift-testing framework needs
explicit search paths).

On first launch:

1. Click the menu bar icon → **Download large-v3-turbo** (~1.6 GB, one time).
2. Hit **Start Recording** → macOS prompts for **Microphone** and
   **Screen Recording** access. Grant both (Screen Recording is what
   unlocks system-audio capture — Sotto discards the video frames).
3. Stop the recording → transcription starts automatically; open
   **Transcripts** to watch it land.

## Usage tips

- Tell the other side you're recording. Depending on your jurisdiction it
  may also be legally required — this tool is for consensual, personal use.
- Transcripts export to Markdown with timestamps — handy for feeding into
  an LLM for summaries and follow-up drafts.
- Pick a model in Settings → Models: `large-v3-turbo` (best, 1.6 GB),
  `small` (466 MB), or `base` (142 MB). Files live in
  `Application Support/Sotto/Models/`; to use a model that isn't offered,
  add a case to `WhisperModel`.
- **Re-transcribe** in the transcript toolbar runs the recording through the
  currently selected model again — the way to redo an old call after
  switching models. The previous transcript stays on screen until the new
  one lands, and survives a failed run.
- Assign a global start/stop shortcut in Settings → General.

## Troubleshooting

### System audio is empty on macOS 15 (even though permission looks granted)

On macOS 15, ad-hoc-signed apps (which is what `bundle.sh` produces) often
fail to obtain Screen Recording access through the normal prompt, and the
permission silently breaks every time the app is rebuilt. There is no
programmatic workaround — add the app manually:

1. Open **System Settings → Privacy & Security → Screen & System Audio
   Recording**.
2. If Sotto is listed, select it and remove it with **−**.
3. Click **+**, pick the built `Sotto.app` (e.g. in `/Applications`), and
   enable it.
4. Relaunch Sotto.

Sotto shows a hint with a shortcut to this settings pane whenever it can't
reach system audio — both when the permission is denied outright and when
capture starts but stays silent.

The same breakage also stops Sotto naming browser calls: window titles are
gated behind Screen Recording, so without it a Google Meet is only detected
by the generic "a call in your browser" fallback. Re-adding the app fixes
both at once.

### One side of the call is silent

After a recording where one track has signal and the other doesn't, Sotto
attaches a warning to the recording (visible in the menu bar and in the
transcript view). If **Them** is silent, check the Screen Recording
permission (above) and that the call audio actually plays through this Mac.
If **Me** is silent, check the selected microphone input device in System
Settings → Sound.

### You hear yourself in the transcript / echo in the "Them" track

Sotto enables Apple's acoustic echo cancellation on the microphone so the
remote voice coming out of your speakers doesn't re-enter your mic track.
If echo cancellation can't be enabled on your audio device, Sotto logs a
message (Console.app, subsystem `dev.sotto`) and records without it — use
headphones in that case.

Whatever echo cancellation leaves behind is dropped before transcription:
mic audio that sits 10 dB or more below the system track at the same moment
is leakage, not speech, so it never reaches Whisper. The audio file still
contains it — only the transcript is filtered.

### Segments appear in the wrong order

Whisper stretches a segment across any silence it is handed, so a track
transcribed in one pass gets timestamps anchored to where the clip starts
rather than where the speech is. Sotto therefore splits each track into
speech regions (gaps of 1.5 s or more) and transcribes them one at a time,
offsetting each region's timestamps by its own position. If you still see
Me and Them interleaved wrongly, the recording itself is worth checking —
open the WAV and confirm the two channels line up.

### Build breaks on a future toolchain

whisper.cpp is pinned to v1.7.2, the last release that builds through SwiftPM
with Metal. If that ever stops working, the contingency is a vendored static
build (CMake + `libtool -static` + a `systemLibrary` target) — not currently
implemented.

## Known limitations (v0.1)

- **Diarization is per-side, not per-person** — segments are labeled
  Me (mic) / Them (system audio). Multiple remote participants all land
  in "Them".
- **The live draft is a draft.** During the call Sotto re-transcribes a
  sliding window of recent audio; the full-quality pass still runs after
  the call ends and replaces the draft.
- **Browser calls work everywhere except Safari.** Chrome, Edge, Brave, Arc
  and Vivaldi are detected; WebKit routes audio through a
  `com.apple.WebKit.GPU` process shared with Mail, Notes and every WKWebView
  host, so Safari's mic use can't be attributed to Safari.
- **Naming the service reads the window title, which is the active tab.**
  Sotto says "Google Meet" when the Meet tab is in front. On another tab it
  falls back to sustained mic-plus-speaker use and says "a call in Chrome"
  after ~15 s — switchable off in Settings → General, since that heuristic
  occasionally catches non-call audio.
- Drift correction assumes both streams stay on one device for the whole
  recording; swapping the input device mid-call limits its accuracy.

## Roadmap

### Transcription and understanding

- [ ] Automatic post-call summary with agreements and action items (local
      model or API)
- [x] Baseline speaker diarization by channel (Me / Them with timestamps)
- [ ] Full-text search across all locally stored transcripts
- [ ] Clickable transcript timestamps that seek to the matching audio

### UX and motion

- [ ] Live, audio-driven waveform in the menu bar icon while recording
- [ ] Smooth decrescendo animation when recording stops
- [ ] Audio-level indicator that transitions from Ink to Record red as volume
      rises

### Practical features

- [ ] Automatic tags and folders based on the source app (Zoom, Meet,
      FaceTime, and others)
- [x] Markdown export with timestamps
- [ ] PDF export with timestamps
- [x] Global hotkey to start/stop (record one in Settings → General)
- [ ] Quote clips: select transcript text and export the corresponding audio
      fragment

### Beta1 foundations

- [x] Per-track recording (mic / system as separate WAV channels) → cheap
      2-speaker diarization for free
- [x] Model downloading progress bar
- [x] Streaming transcription during the call (sliding-window live draft;
      final full pass after stop)
- [x] Drift correction via timestamp anchoring (host-clock anchors →
      t0 alignment + rate correction at stop)
- [x] Model picker + smaller-model presets (large-v3-turbo / small / base
      in Settings → Models)
- [x] Auto-detect call start (mic in use by a call app → notification
      with a Start-recording button; never auto-starts)
- [x] Browser call detection (Google Meet in Chrome/Edge/Brave/Arc/Vivaldi
      via window-title rules, with a sustained mic-plus-speaker fallback)

## License

MIT

## Brand

Mark, palette, and usage rules live in [`docs/brand.md`](docs/brand.md);
SVG assets in [`assets/`](assets/). Generate the app icon with
`./scripts/make-icns.sh` (requires `brew install librsvg`).
