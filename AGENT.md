# Shortcast Agent Notes

## Product Direction

Shortcast is currently being reshaped from a social-short captioning app into a
tool for turning long educational videos into concise, subtitled highlight
videos and reviewed subtitled cuts.

The primary flow is:

1. Drop a lecture, podcast, interview, or long recording.
2. Transcribe it from a sidecar `.srt`/`.vtt`, WhisperKit, or MiMo ASR.
3. Use MiMo to plan one coherent 5-15 minute educational highlight.
4. Cut and join selected ranges with AVFoundation.
5. Burn readable subtitles into the rendered video.
6. Show one downloadable highlight with title, summary, and segment list.

The full-video subtitle flow is also important:

1. Drop a long video.
2. Transcribe and translate/rewrite subtitles for review.
3. Let the user include/exclude subtitle cues, including "Deselect all" then
   choosing only the moments they want.
4. Render selected cues as one joined short, or render the full subtitled video.
5. Keep the review screen open so the user can render more cuts from the same
   source video.

Avoid reintroducing "viral", "scroll-stopping", TikTok/Reels/Shorts, hashtags,
or platform-caption framing into prompts or primary UI copy unless explicitly
working on the legacy publishing flow or the optional post-render publishing
copy helper. The user explicitly wants caption and hashtag suggestions available
after rendering highlights and full-video/selected-clip outputs, behind a
toggle so it does not clutter the main workflow.

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
  `planHighlight(...)`. The highlight system prompt lives here. It also owns
  post-render publishing-copy generation for rendered highlights and translated
  video outputs.

- `Shortcast/Services/MediaExtractor.swift`
  Owns media inspection, cutting, highlight rendering, subtitles, and overlay
  composition via AVFoundation.

- `Shortcast/Services/TranscriptionService.swift`
  Owns sidecar transcript loading and transcription backend routing.

- `Shortcast/Services/PromptBuilder.swift`
  Legacy Gemma prompt builder. It now supports the explicit legacy publishing
  helper path for captions and hashtags. Do not remove that behavior when
  keeping the main educational highlight flow grounded.

- `Shortcast/Resources/social-content-coach.md`
  Despite the old filename, this is primarily an educational content editor
  brief. It also documents the explicit legacy publishing helper exception.

- `Shortcast/Services/MomentFinderService.swift`
  Legacy transcript clip helper. The current headline highlight planner does
  not use this path.

- `Shortcast/Models/AppSettings.swift`
  User settings, including MiMo API config, transcription backend, subtitle
  language, highlight aspect ratio, optional post-render publishing-copy
  suggestions, and legacy clip summarizer model.

- `Shortcast/Views/SubtitleReviewView.swift`
  Review UI for translated/highlight subtitles. This is where users select
  which cues to include, deselect/select all cues, repeatedly render selected
  joined clips from the same source, download outputs, and optionally generate
  captions/hashtags for rendered full-video or selected-clip outputs.

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

Post-render publishing copy is no longer purely legacy: highlight and full-video
result views can show a toggle for "Suggest captions and hashtags". Keep this
helper optional and scrollable where space is tight, especially inside subtitle
review.

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
- Keep the default highlight output focused on one coherent educational video.
  The subtitle review flow is allowed to render multiple selected cuts from the
  same source video because the user explicitly requested that workflow.
- Keep caption/hashtag UI optional behind a toggle. It should not block review,
  rendering, or downloading. Hashtag fields must be visible and scrollable when
  long platform suggestions are generated.
- Do not invent new broad abstractions while legacy and highlight paths still
  coexist. Keep changes scoped and explicit.
- When renaming legacy concepts, do it in small passes and build after each pass.
