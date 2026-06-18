# Shortcast Agent Notes

## Product Direction

Shortcast is now focused on turning K-pop performance videos into one concise,
subtitled montage. The main flow is performance-first, not lecture-first:

1. Drop a K-pop stage, fancam, dance practice, MV, or live performance.
2. Transcribe from a sidecar `.srt`/`.vtt`, WhisperKit, or MiMo ASR when text is
   available.
3. Run local audio/visual analysis for performance candidates: energy,
   beat/onset changes, scene changes, and performer face density.
4. Send the compact candidate list plus nearby transcript/lyrics to MiMo to plan
   one coherent 60-180 second montage.
5. Cut and join selected ranges with AVFoundation.
6. Burn styled subtitles into the rendered video.
7. Show one downloadable montage with title, summary, segment list, subtitles,
   and optional post-render publishing copy.

Manual subtitle review for the montage must review only cues inside the selected
montage ranges. Do not make users review an entire source-video transcript for a
K-pop highlight.

The full-video subtitle flow is still important:

1. Drop a long video.
2. Transcribe and translate/rewrite subtitles for review.
3. Let the user include/exclude subtitle cues, including "Deselect all" then
   choosing only the moments they want.
4. Render selected cues as one joined short, or render the full subtitled video.
5. Keep the review screen open so the user can render more cuts from the same
   source video.

Avoid inventing member names, group names, song titles, rankings, fandom claims,
or official affiliation unless they appear in provided metadata, transcript,
filename, or user-supplied text. Keep social publishing copy optional behind a
toggle; it should not clutter the main workflow.

## Important Runtime Behavior

Gemma is lazy-loaded. Do not load Gemma at app launch.

- `ShortcastApp.swift` should not call `modelManager.prepareIfNeeded()` on
  startup.
- `ContentView` should not gate the drop zone behind `modelManager.isReady`.
- The montage flow should run through MiMo/Whisper/AVFoundation without
  requiring local Gemma weights in RAM.
- Gemma should be prepared only when the user chooses the legacy short-summary
  helper or another feature that truly needs `GemmaService`.

If Gemma is loaded for a legacy task, it currently remains resident until the app
closes or explicit unload logic is added.

## Key Files

- `Shortcast/Services/WorkspaceModel.swift`
  Owns the main state machine. The default mode is K-pop montage creation. It
  wires transcription, `KpopSignalAnalyzer`, MiMo planning, review, rendering,
  and completion notifications.

- `Shortcast/Services/KpopSignalAnalyzer.swift`
  Builds local candidate windows from audio energy/onsets, sampled visual scene
  changes, performer face density, and nearby transcript snippets.

- `Shortcast/Services/MimoService.swift`
  Owns MiMo chat completions, ASR, subtitle translation, and
  `planHighlight(...)`. The K-pop montage system prompt lives here. It also owns
  post-render publishing-copy generation.

- `Shortcast/Services/MediaExtractor.swift`
  Owns media inspection, cutting, montage rendering, styled subtitles, and
  overlay composition via AVFoundation.

- `Shortcast/Services/TranscriptionService.swift`
  Owns sidecar transcript loading, transcription backend routing, and helpers
  for clipping transcripts to selected montage ranges.

- `Shortcast/Models/AppSettings.swift`
  User settings, including MiMo API config, transcription backend, subtitle
  language, subtitle visual style, subtitle placement, aspect ratio, optional
  publishing-copy suggestions, and legacy clip summarizer model.

- `Shortcast/Views/SubtitleReviewView.swift`
  Review UI for translated/montage subtitles. The preview should resemble the
  rendered output: subtitle style, subtitle position, and selected cue text
  should appear over the video.

- `Shortcast/Services/PromptBuilder.swift`
  Legacy Gemma prompt builder. It supports the explicit legacy publishing helper
  path for captions and hashtags. Do not remove that behavior when keeping the
  main K-pop montage flow grounded.

- `Shortcast/Resources/social-content-coach.md`
  Despite the generic filename, this is now the K-pop performance editor brief.

- `Shortcast/Services/MomentFinderService.swift`
  Legacy transcript clip helper. The current headline montage planner does not
  use this path.

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

Unit-test command:

```bash
xcodebuild test -project Shortcast.xcodeproj -scheme Shortcast -skipMacroValidation -destination 'platform=macOS'
```

Without `-skipMacroValidation`, Xcode may fail before compiling the app with:

```text
Macro "MLXHuggingFaceMacros" from package "mlx-swift-lm" must be enabled before it can be used
```

That macro gate is external package/Xcode behavior, not usually caused by app
source changes.

## Editing Guidance

- Preserve lazy Gemma loading.
- Keep prompts grounded, K-pop performance-aware, and subtitle-aware.
- Keep the default output focused on one coherent montage.
- Manual montage subtitle review should show only selected montage cues.
- Styled subtitle choices should affect both preview and final render.
- Completion notifications should fire only after a render output is actually
  available.
- Keep caption/hashtag UI optional behind a toggle.
- Do not invent broad abstractions while legacy and montage paths still coexist.
  Keep changes scoped and explicit.
- When renaming legacy concepts, do it in small passes and build after each pass.
