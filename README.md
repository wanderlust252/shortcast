<div align="center">

# Shortcast

**Long videos → concise, subtitled highlight videos.**
**Transcribed, summarized, cut, subtitled and rendered from your Mac. Open-source.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-1d1d1f)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Model](https://img.shields.io/badge/Gemma_4_12B-on--device-4285F4)
![Whisper](https://img.shields.io/badge/WhisperKit-large--v3-00B8D9)

<br />

<img src="assets/demo.gif" alt="Shortcast demo — drop a long video, get a summarized subtitled highlight" width="720" />

<br />

<sub>Drop a long video → it transcribes, plans one coherent highlight, cuts the useful sections, burns subtitles, and renders a downloadable video.</sub>

</div>

---

## What it does

Shortcast has two modes:

### 🎬 Make a highlight video (the main one)

Drop a lecture, podcast, interview or long recording. Shortcast transcribes it,
asks MiMo to plan one coherent **5-15 minute educational highlight**, cuts the
useful sections, adds readable subtitles, and renders a single downloadable video.
You can keep the original aspect ratio for slides/interviews or render a
phone-friendly 9:16 version.

### ✏️ Summarize a short

Already have a short clip? Drop it and Shortcast can still use the legacy helper
path to write grounded titles and notes from the clip.

What's different about Shortcast:

- 🧠 **Summary-first planning.** The planner preserves the learning path: context,
  core concepts, examples, warnings, and takeaways.
- 🔤 **Readable subtitles.** Selected transcript cues are burned into the rendered
  highlight, with optional Vietnamese subtitle translation.
- 📐 **Two output shapes.** Original ratio preserves slides and wide interviews;
  vertical 9:16 works well for phone viewing.
- 🛰️ **Local media processing.** Cutting, rendering, and local model helpers stay
  on your Mac. MiMo features use your configured API key.
- 🪶 **No Python. No Electron. No embedded runtime.** Just Swift, MLX, AVFoundation, Vision.

## How a long video becomes a highlight

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  YOUR MAC                                                            │
  │                                                                       │
  │  drop a long video                                                    │
  │        │                                                              │
  │        ▼                                                              │
  │  ┌──────────────┐   ┌────────────────────┐   ┌────────────────────┐   │
  │  │ WhisperKit   │──►│  MiMo planner       │──►│ AVFoundation       │   │
  │  │ or MiMo ASR  │   │  summary + EDL      │   │ cut + join ranges  │   │
  │  │ transcribe   │   │  for one highlight  │   │ burn subtitles     │   │
  │  └──────────────┘   └────────────────────┘   └────────────────────┘   │
  │                                                       │                │
  │                                                       ▼                │
  │                                              ┌───────────────────┐     │
  │                                              │ one highlight:    │     │
  │                                              │ title, summary,   │     │
  │                                              │ subtitles, mp4    │     │
  │                                              └───────────────────┘     │
  └──────────────────────────────────────────────────────────────────────┘
```

Concretely:

1. **Transcribe.** If the video has a `.srt`/`.vtt` sidecar, it's used instantly.
   Otherwise WhisperKit or MiMo ASR creates a transcript.
2. **Plan the highlight.** MiMo reads the timestamped transcript and returns a
   JSON edit decision list: title, summary, and selected segments.
3. **Cut and join.** AVFoundation cuts the selected source ranges and joins them
   into one highlight video.
4. **Subtitle.** Shortcast burns readable subtitle cues into the rendered output.
   It can translate selected highlight cues to Vietnamese before rendering.
5. **Review.** Play the rendered highlight, inspect its title/summary/segments,
   and download the `.mp4`.

### Choosing the model

Settings → *Legacy clip summarizer* picks the helper model used by older
single-clip paths:

| Model | Role | Notes |
|-------|------|-------|
| **Gemma 4 12B** (default) | Legacy transcript helper | Finds useful clip ranges and writes grounded summaries. |
| **Qwen 3.5 9B** | Legacy transcript helper | Lighter transcript-based summaries with a large context window. |
| **Gemma 4 E4B** | Clip-watching helper | Multimodal — watches a clip (frames + audio) before writing a grounded summary. |

The model downloads once on first use. Everything runs offline afterwards.

## Install

> Releases are unsigned (not yet notarized), so macOS Gatekeeper blocks them the
> first time. This is expected — one Terminal command fixes it.

1. Download `Shortcast.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **Shortcast** to your Applications folder.
3. Strip the download-quarantine flag, then open the app normally:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Shortcast.app
   ```

   Now double-click Shortcast and it launches.

> [!NOTE]
> **Seeing “Shortcast.app is damaged and can’t be opened”?** That's the same
> Gatekeeper quarantine — on Apple Silicon, recent macOS shows *“damaged”*
> instead of *“unidentified developer”* and hides the **Open Anyway** button. The
> app is **not** actually damaged; the `xattr` command above is the fix.

<details>
<summary>Prefer the GUI? (older macOS)</summary>

Double-click Shortcast, then open **System Settings → Privacy & Security**, scroll
to the message about Shortcast and click **Open Anyway**. On recent macOS this
button often doesn't appear for unsigned apps — use the Terminal command instead.
</details>

### First run

- Shortcast downloads the models it needs on first use, with a visible progress bar:
  the **Director** (Gemma 4 12B ≈ 7 GB, or Qwen 3.5 9B ≈ 5 GB) and **WhisperKit
  large-v3** for transcription. Happens once, then it works offline.
- Open **Settings** (⌘,) and choose a publishing provider. Upload-Post needs an
  [Upload-Post](https://upload-post.com) **API key** and **profile name**. TikTok
  official API needs a TikTok user access token; see
  [docs/tiktok-official-publishing.md](docs/tiktok-official-publishing.md).
- Optionally set a caption language and paste a few of your own captions as style
  examples — the model will match your voice.

You can generate shorts without a publishing provider; only publishing/scheduling needs one.

## Build from source

You need **Xcode 16+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
On Apple Silicon. macOS 15+.

```bash
brew install xcodegen
git clone https://github.com/mutonby/shortcast
cd shortcast
xcodegen generate
open Shortcast.xcodeproj
```

Build and run the **Shortcast** scheme. The `.xcodeproj` is generated from
`project.yml` and intentionally not committed — `xcodegen` regenerates it.

> CLI builds need `-skipMacroValidation`:
>
> **Debug build:**
> ```bash
> xcodebuild -project Shortcast.xcodeproj -scheme Shortcast \
>   -configuration Debug -skipMacroValidation -destination 'platform=macOS' build
> ```
>
> **Release build:**
> ```bash
> xcodebuild -project Shortcast.xcodeproj -scheme Shortcast \
>  -configuration Release -skipMacroValidation -destination 'platform=macOS' \
>  SYMROOT=$(pwd)/build build
> ```

### Release DMG

`.github/workflows/release.yml` builds an unsigned `.dmg` and attaches it to the
GitHub Release whenever a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## The stack

| Layer            | Used                                                                  |
|------------------|-----------------------------------------------------------------------|
| UI               | SwiftUI · AVKit                                                       |
| Transcription    | [WhisperKit](https://github.com/argmaxinc/WhisperKit) `large-v3` (Metal/GPU) |
| Director model   | Gemma 4 12B or Qwen 3.5 9B (4-bit), runs as a text LLM via MLX        |
| Clip-watcher     | Gemma 4 E4B (4-bit), text + vision + audio                           |
| Inference        | [MLX](https://github.com/ml-explore/mlx-swift) (Metal, Neural Engine) |
| Gemma 4 runtime  | [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx), vendored in `Vendor/` |
| Vertical reframe | Vision (face detection) + AVFoundation (transform ramps / Core Image)|
| Media            | AVFoundation (cut, sample, export) · AVKit playback                  |
| Publishing       | [Upload-Post](https://upload-post.com) API, or TikTok official Content Posting API |
| Build            | XcodeGen · GitHub Actions                                            |

## Privacy

Transcription, moment-finding, captioning, cutting and reframing all run inside the app,
on your Mac. The only outbound traffic before you publish is:

- **First use only**: one-time downloads of the model weights from Hugging Face.
- **On Publish / Schedule**: an upload to the selected publishing provider with the
  rendered short and the copy you approved. Upload-Post can publish/schedule multiple
  networks; TikTok official API uploads only TikTok.

Publishing credentials are stored locally on your Mac (app preferences) and are only sent
to their provider over HTTPS when needed. They are never written into the repository.

## Known limitations

- The **Director** runs a large model on-device. On an M1 Pro, a ~2-minute video takes a
  few minutes end-to-end (transcription + generation). Faster Macs (M3/M4) are quicker.
- *Caption a short* uses Gemma 4 E4B, whose audio encoder hears the **first 30 seconds**.
- The app is **unsigned** (see *Install*). Code signing + notarization will come once the
  project stabilises.
- One video at a time — no history, no batch processing. By design, for now.
- Upload-Post free tier limits monthly uploads. One publish to three networks counts as
  three.

## Acknowledgements

- **Google** for the Gemma 4 family — open weights with full multimodal capability.
- **Apple's MLX team** for [MLX](https://github.com/ml-explore/mlx-swift) and
  [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
- **Vincent Gourbin** for [gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx),
  the native Gemma 4 runtime we vendor.
- **Argmax** for [WhisperKit](https://github.com/argmaxinc/WhisperKit).
- **Alibaba** for the Qwen 3.5 open weights.
- **Upload-Post** for the cross-platform publishing API.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Third-party components are listed in [NOTICE](NOTICE). The vendored
`gemma-4-swift-mlx` runtime is MIT-licensed; the Gemma 4 weights are governed by
[Google's Gemma Terms of Use](https://ai.google.dev/gemma/terms).

<div align="center">
<sub>Built in the open.</sub>
</div>
