# Shortcast Agent Notes

## Product Direction

Shortcast is currently being reshaped from a social-short captioning app into a
tool for turning long educational videos into concise, subtitled highlight
videos.

The primary flow is:

1. Drop a lecture, podcast, interview, or long recording.
2. Transcribe it from a sidecar `.srt`/`.vtt`, WhisperKit, or MiMo ASR.
3. Use MiMo to plan one coherent 5-15 minute educational highlight.
4. Cut and join selected ranges with AVFoundation.
5. Burn readable subtitles into the rendered video.
6. Show one downloadable highlight with title, summary, and segment list.

Avoid reintroducing "viral", "scroll-stopping", TikTok/Reels/Shorts, hashtags,
or platform-caption framing into prompts or primary UI copy unless explicitly
working on the legacy publishing flow.

## Important Runtime Behavior

Gemma is now lazy-loaded. Do not load Gemma at app launch.

- `ShortcastApp.swift` should not call `modelManager.prepareIfNeeded()` on
  startup.
- `ContentView` should not gate the drop zone behind `modelManager.isReady`.
- The highlight flow should run through MiMo/Whisper/AVFoundation without
  requiring local Gemma weights in RAM.
- Gemma should be prepared only when the user chooses the legacy short-summary
  helper or another feature that truly needs `GemmaService`.

If Gemma is loaded for a legacy task, it currently remains resident until the app
closes or explicit unload logic is added.

## Key Files

- `Shortcast/Services/WorkspaceModel.swift`
  Owns the main state machine. The default mode is long-video highlight creation.
  The legacy single-clip path calls Gemma lazily.

- `Shortcast/Services/MimoService.swift`
  Owns MiMo chat completions, ASR, subtitle translation, and
  `planHighlight(...)`. The highlight system prompt lives here.

- `Shortcast/Services/MediaExtractor.swift`
  Owns media inspection, cutting, highlight rendering, subtitles, and overlay
  composition via AVFoundation.

- `Shortcast/Services/TranscriptionService.swift`
  Owns sidecar transcript loading and transcription backend routing.

- `Shortcast/Services/PromptBuilder.swift`
  Legacy Gemma prompt builder. It should remain educational/summary-oriented,
  not social-caption-oriented.

- `Shortcast/Resources/social-content-coach.md`
  Despite the old filename, this is now an educational content editor brief.

- `Shortcast/Services/MomentFinderService.swift`
  Legacy transcript clip helper. The current headline highlight planner does
  not use this path.

- `Shortcast/Models/AppSettings.swift`
  User settings, including MiMo API config, transcription backend, subtitle
  language, highlight aspect ratio, and legacy clip summarizer model.

## Legacy Areas

These still exist and may contain social/publishing concepts because they are
real older features, not the current main direction:

- `UploadPostClient`
- `TikTokOfficialProvider`
- `PostVariant`
- `SocialPlatform`
- `ShortClip`
- `ShortsResultsView`
- `PostPreviewCard`

Before deleting them, check references from `WorkspaceModel`, result views, and
publishing providers. Prefer hiding or isolating legacy UI before large removals.

## Build Notes

Use XcodeGen project files already present in the repo.

Common build command:

```bash
xcodebuild -project Shortcast.xcodeproj -scheme Shortcast -configuration Debug -skipMacroValidation build
```

Without `-skipMacroValidation`, Xcode may fail before compiling the app with:

```text
Macro "MLXHuggingFaceMacros" from package "mlx-swift-lm" must be enabled before it can be used
```

That macro gate is external package/Xcode behavior, not usually caused by app
source changes.

## Editing Guidance

- Preserve lazy Gemma loading.
- Keep prompts grounded, educational, and subtitle-aware.
- Keep highlight output focused on one coherent video, not a set of social
  shorts.
- Do not invent new broad abstractions while legacy and highlight paths still
  coexist. Keep changes scoped and explicit.
- When renaming legacy concepts, do it in small passes and build after each pass.
