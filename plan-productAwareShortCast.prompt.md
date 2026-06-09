# Plan: Product-Aware ShortCast — Merged Best-of-Both

> Merged from `PLAN.md` (English, architecture) + `implementation_plan.md` (Vietnamese, code specifics).
> Decisions locked on 2026-06-09.

---

## Overview

Two features that share product-awareness infrastructure:

| Feature | Goal | Approach |
|---------|------|----------|
| **A — Product Tracking** | Reframe 16:9 → 9:16 by following products (not just faces) | YOLOv8-Nano CoreML + existing `VerticalReframer` pipeline |
| **B — Product Template Matching** | Find video segments containing a specific product (by reference image) | Gemma 4 Vision Embedding + cosine similarity |

---

## Feature A: Product Tracking (Vertical Reframing)

### Summary

Extend `VerticalReframer` from face-only to multi-target tracking. Add CoreML object detection alongside Apple Vision face detection. Three modes: `speaker` (current), `product` (CoreML), `auto` (smart switching).

### Decisions ✅

- **Model**: Bundled YOLOv8-Nano `.mlpackage` (~15-30MB), offline after install
- **Multi-object selection**: Auto — confidence + center proximity
- **Auto mode threshold**: product confidence ≥ 0.7 to prefer over speaker
- **Pan parameters**: Keep existing, tune after real-world testing

---

### Phase 1: Refactor Abstract Focus Layer

**Step 1.1** — Rename `Sample` → `FocusSample` in `VerticalReframer.swift`
- Keep interface: `{ time: Double, midX: CGFloat? }`
- `panPath()` still receives `[FocusSample]` — no logic change
- Goal: `sampleFaces()` and `sampleProducts()` return the same type

**Step 1.2** — Add `FocusMode` enum to `AppSettings.swift`

```swift
enum FocusMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case speaker    // Face tracking (default, current behavior)
    case product    // CoreML object detection
    case auto       // Prefer product when confident, fallback to speaker
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .speaker: "Face Tracking"
        case .product: "Product Tracking"
        case .auto:    "Auto (Product → Face)"
        }
    }
}
```

- Add `focusMode: FocusMode` to `AppSettings` with `UserDefaults` persistence
- Default: `.speaker` (backward compatible)

**Step 1.3** — Add per-clip `focusMode` to `ShortClip.swift`

```swift
var focusMode: FocusMode?  // nil = use global default
```

- Update `makeRenderedFile()` to pass `focusMode` to `VerticalReframer.process()`
- Existing clips keep `nil` → default to `.speaker`

**Files:**
- `Shortcast/Services/VerticalReframer.swift` — rename Sample → FocusSample
- `Shortcast/Models/AppSettings.swift` — add FocusMode enum + property
- `Shortcast/Models/ShortClip.swift` — add per-clip focusMode

---

### Phase 2: CoreML Product Detector

**Step 2.1** — Bundle CoreML model
- Convert YOLOv8-Nano or YOLOv10-Nano to `.mlpackage`
- Estimated size: 15-30MB
- Add to Xcode app target

**Label mapping:**

| Model label | Product group |
|-------------|---------------|
| `handbag` | bags |
| `shoe`, `sneaker`, `sandal`, `boot` | shoes |
| `bottle`, `cup`, `jar` | cosmetics |
| `shirt`, `pants`, `dress`, `coat`, `jacket` | clothing |
| `watch`, `necklace`, `ring`, `sunglasses`, `earring` | accessories |

**Step 2.2** — Create `ProductFocusDetector` service

New file: `Shortcast/Services/ProductFocusDetector.swift`

```swift
@MainActor
enum ProductFocusDetector {
    nonisolated static func detectProduct(in cgImage: CGImage) -> CGFloat?
    // Returns midX (0…1) of best product, or nil
    // Selection: confidence ≥ threshold → label priority → area → center proximity
}
```

- Load model once (lazy)
- Graceful degradation: model load fail → return nil

**Step 2.3** — Add `sampleProducts()` to `VerticalReframer.swift`
- Same structure as `sampleFaces()` but uses `VNCoreMLRequest`
- Same sampling cadence (0.5s) and image generator setup
- Returns `[FocusSample]` from Phase 1

**Files:**
- `Shortcast/Services/ProductFocusDetector.swift` — NEW
- `Shortcast/Services/VerticalReframer.swift` — add sampleProducts()
- Xcode project — add .mlpackage

---

### Phase 3: Update VerticalReframer Pipeline

**Step 3.1** — Update `process()` signature

```swift
static func process(
    clipURL: URL,
    reframe: Bool,
    overlayText: String?,
    focusMode: FocusMode = .speaker
) async throws -> URL?
```

**Step 3.2** — Mode routing logic

```
.speaker  → sampleFaces()    → panPath() → render (no change)
.product  → sampleProducts() → panPath() → render (same pan logic)
.auto     → run both →
    product samples with confidence ≥ 0.7 → prefer product
    else → fall back to speaker samples
    else → blurred letterbox
```

**Step 3.3** — Update `previewItem()` for focus mode
- Mirror `process()` routing logic
- Ensure preview matches export output

**Step 3.4** — Tune product-specific pan (if needed)
- Products may move faster than faces → may need higher maxSpeed
- Products may disappear suddenly → need hold-position logic
- Decide after real-world testing

**Files:**
- `Shortcast/Services/VerticalReframer.swift` — update process(), previewItem()

---

### Phase 4: UI Updates

**Step 4.1** — `SettingsView.swift`

```swift
Section("Vertical reframing") {
    Toggle("Auto-convert horizontal clips to vertical 9:16",
           isOn: $settings.reframeToVertical)
    if settings.reframeToVertical {
        Picker("Focus tracking", selection: $settings.focusMode) {
            ForEach(AppSettings.FocusMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }
}
```

**Step 4.2** — `ShortClipCard.swift`
- Add per-clip focus mode selector
- Only visible when `isLandscape && reframeEnabled`
- Position: beside existing reframe toggle

**Files:**
- `Shortcast/Views/SettingsView.swift` — add focus mode picker
- `Shortcast/Views/ShortClipCard.swift` — add per-clip selector

---

### Phase 5: Testing (Feature A)

| Type | Tests |
|------|-------|
| **Unit** | Target selection: highest confidence wins · unsupported labels filtered · empty/low-confidence → nil · FocusMode UserDefaults roundtrip |
| **Regression** | `.speaker` unchanged · no faces/products → blurred · overlay works with all modes · existing clips default to `.speaker` |
| **Manual** | Person talking → speaker · product demo → product · fashion → auto switches · preview = export |

---

## Feature B: Product Template Matching

### Summary

User drops video + reference product image → system scans entire video using Vision Embedding similarity → creates ClipCandidates for segments containing that product → displays alongside Director moments in the clip grid.

### Decisions ✅

- **Approach**: Vision Embedding (extract vectors from Gemma 4 VisionEncoder, cosine similarity)
- **Workflow**: Drop reference image before analysis (proactive)
- **Output**: Create new ClipCandidates (merge with Director moments in grid)
- **Similarity threshold**: ≥ 0.7 (tune empirically)
- **App size impact**: +0MB (uses existing Gemma 4 model)

### Pipeline

```
[Video + Reference Image] → drop into app
    ↓ (parallel)
┌──────────────────────────┬─────────────────────────────────┐
│ Transcribe (WhisperKit)  │ Director: findMoments(transcript)│
└────────────┬─────────────┴──────────────┬──────────────────┘
             │                            │
             │    ⭐ ProductScan          │
             │    VisionEncoder(ref_img)  │
             │    → ref_embedding         │
             │                            │
             │    VisionEncoder(frames@1fps)
             │    → frame_embeddings[]    │
             │    cosine_sim(ref, frame)  │
             │    ≥ 0.7 → keep            │
             │    merge nearby frames     │
             │    → product_segments[]    │
             │                            │
             └────────────┬───────────────┘
                          ↓
             Merge: Director moments + Product segments
                          ↓
             ShortClip[] → grid (user review)
                          ↓
             Cut → Caption → Publish
```

### Why Vision Embedding over alternatives?

| Approach | App Size | Speed | Accuracy | New Dependencies |
|----------|----------|-------|----------|-----------------|
| **Vision Embedding (chosen)** | +0MB | <100ms/frame | High (semantic) | None |
| YOLO + Template Matching | +15-30MB | ~50ms/frame | Medium (pixel) | CoreML model |
| CLIP Integration | +400MB | ~200ms/frame | High | CLIP model |

---

### Phase B-1: Embedding Extractor

**Step B1.1** — Expose VisionPooler output from Gemma 4
- Currently: VisionEncoder → VisionPooler → MultimodalEmbedder → text space
- Need: VisionEncoder → VisionPooler → **raw embedding vector** (before text projection)
- Modify `Vendor/gemma-4-swift-mlx/` or add extraction hook in `GemmaService.swift`

**Step B1.2** — Implement cosine similarity on MLX

```swift
// Using existing MLX array operations
func cosineSimilarity(_ a: MLXArray, _ b: MLXArray) -> Float {
    let normA = a / sqrt(sum(a * a))
    let normB = b / sqrt(sum(b * b))
    return sum(normA * normB).item(Float.self)
}
```

**Files:**
- `Shortcast/Services/ProductMatcherService.swift` — NEW orchestrator
- `Vendor/gemma-4-swift-mlx/` — expose embedding extraction

---

### Phase B-2: Segment Scanner

**Step B2.1** — Scan video at 1fps
- Reuse `AVAssetImageGenerator` pattern from `VerticalReframer.sampleFaces()`
- Extract VisionEmbedding for each frame
- Compute cosine similarity with reference embedding

**Step B2.2** — Merge nearby frames into segments
- Consecutive frames with similarity ≥ 0.7 → group into segment
- Add padding: extend each segment by 1-2s on each side
- Minimum segment duration: 5s (discard shorter)
- Maximum segment duration: 60s (split longer)

**Step B2.3** — Create ClipCandidates

```swift
ClipCandidate(
    start: segment.start - padding,
    end: segment.end + padding,
    why: "Contains matching product (confidence: 0.85)",
    hook: "",        // Director-style hook can be generated later
    overlay: ""      // or user can edit
)
```

**Files:**
- `Shortcast/Services/ProductMatcherService.swift`

---

### Phase B-3: Pipeline Integration

**Step B3.1** — Update `WorkspaceModel.runShortsPipeline()`

```swift
// After transcription, in parallel:
async let directorMoments = MomentFinderService.findMoments(...)
async let productSegments = ProductMatcherService.findSegments(
    videoURL: url,
    referenceImage: refImage,
    threshold: 0.7
)

let director = await directorMoments
let products = await productSegments

// Merge: Director first (ranked), then product segments (marked)
let allCandidates = director + products
```

**Step B3.2** — Update `ContentView.swift` state machine
- Add new phase: `.scanningProduct` (with progress indicator)
- Accept reference image input alongside video drop

**Step B3.3** — Mark product-match clips
- Add optional `isProductMatch: Bool` to `ShortClip`
- Display badge on `ShortClipTile` (e.g., small product icon)

**Files:**
- `Shortcast/Services/WorkspaceModel.swift` — add parallel product scan
- `Shortcast/Views/ContentView.swift` — accept reference image, new phase
- `Shortcast/Models/ShortClip.swift` — optional isProductMatch flag

---

### Phase B-4: UI

**Step B4.1** — Update `DropZoneView.swift`
- Accept both video and image drops
- Show reference image thumbnail after drop
- Allow removing/replacing reference image

**Step B4.2** — Update `ShortsResultsView.swift`
- Product-match clips get a visual badge/indicator
- Optional: separate section or filter for product matches

**Step B4.3** — Progress indicator
- Show "Scanning for product…" during embedding extraction
- Progress: X/total frames scanned

**Files:**
- `Shortcast/Views/DropZoneView.swift` — dual drop (video + image)
- `Shortcast/Views/ContentView.swift` — new scanning phase
- `Shortcast/Views/ShortsResultsView.swift` — product match badge

---

### Phase B-5: Testing (Feature B)

| Type | Tests |
|------|-------|
| **Unit** | Cosine similarity correctness · segment merging logic · minimum/maximum duration clamping · padding calculation |
| **Integration** | End-to-end: video + reference image → ClipCandidates appear in grid |
| **Manual** | Product visible in 3 segments of a 30-min video → 3 ClipCandidates created · product never appears → 0 candidates · product visible briefly → discarded if <5s · reference image replaced → results update |

---

## Implementation Order

```
Feature A (Product Tracking)              Feature B (Template Matching)
  Phase 1 → 2 → 3 → 4 → 5                 Phase B-1 → B-2 → B-3 → B-4 → B-5
  ████████████████████████                  ████████████████████████
  ← Do first (simpler, self-contained)      ← Do second (needs Gemma internals)
```

**Feature A first** because:
1. Fewer architectural changes (extends existing `VerticalReframer`)
2. Can test immediately with any landscape video
3. Feature B requires exposing Gemma VisionEncoder internals → more complex

---

## Files Summary

### New files
| File | Feature | Purpose |
|------|---------|---------|
| `Shortcast/Services/ProductFocusDetector.swift` | A | YOLOv8 CoreML inference for per-frame product detection |
| `Shortcast/Services/ProductMatcherService.swift` | B | Vision embedding extraction + similarity + segment merging |
| `ProductDetector.mlpackage` | A | Bundled CoreML object detection model |

### Modified files
| File | Feature | Changes |
|------|---------|---------|
| `Shortcast/Services/VerticalReframer.swift` | A | Rename Sample, add sampleProducts(), update process() & previewItem() |
| `Shortcast/Models/AppSettings.swift` | A | Add FocusMode enum + UserDefaults property |
| `Shortcast/Models/ShortClip.swift` | A+B | Add focusMode (A), optional isProductMatch (B) |
| `Shortcast/Views/SettingsView.swift` | A | Add focus mode picker |
| `Shortcast/Views/ShortClipCard.swift` | A | Add per-clip focus selector |
| `Shortcast/Views/ContentView.swift` | B | Accept reference image, add scanning phase |
| `Shortcast/Views/DropZoneView.swift` | B | Dual drop (video + image) |
| `Shortcast/Views/ShortsResultsView.swift` | B | Product match badge on tiles |
| `Shortcast/Services/WorkspaceModel.swift` | B | Parallel product scan in pipeline |
