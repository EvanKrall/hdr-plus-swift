# Plan: Alignment Inspection View (pre-merge visualization)

> **Status: Phases 1–5 complete — CLI verified + SwiftUI inspector window shipped.**
> - `align_texture_ex` / `AlignmentOutput` refactor done; gui + cli targets compile clean.
> - `burstphoto/viz/visualize.{metal,swift}`: alignment field (RGB-axes + HSV-flow, with anchor-relative offset), abs-difference, signed color difference (red = warped brighter, blue = darker), tonemapped 8-bit previews, CPU readback helpers, robust inlier-maximizing brightness fit, CPU thumbnail tonemapping.
> - `burstphoto/inspect/inspect.swift`: `perform_alignment_inspection` + `InspectionSession` (align-only, on-demand rendering).
> - `burstphoto/inspect/AlignmentInspectorView.swift`: inspector window (plain NSWindow for macOS 11 compatibility) — mode picker (Alignment | Flow | Difference | Warped | Reference), mode-following thumbnails, shared burst-wide scales for alignment color and difference white point, anchor point (click → per-frame relative alignment), anchor-local robust brightness fit, checkbox + cmd/shift multi-select frame exclusion, arrow-key navigation, Merge button (all or only included frames).
> - `burstphoto/cli.swift`: `inspect <dir>` mode (PNG export + stats.txt) and `selftest` mode (31 checks, synthetic ground truth) — all passing.
> - `build_gui_manual.sh`: manual GUI build (xcodebuild/actool broken on this machine; qlmanage-rasterized drop icon).
> - Verified on real RAW data: 12-frame astro burst + 100-frame owl burst (NEF → DNG via Adobe DNG Converter).
> - Remaining: merge-regression bit-comparison (merge verified functionally, not bit-exact); optional: reuse computed alignments in the merge.

Goal: after importing a burst, let the user inspect — per candidate frame, against the reference —
1. the **alignment field** (per-tile X/Y shift mapped to color), and
2. the **difference image** between the warped candidate and the reference.

---

## Current architecture (facts that drive the design)

- `perform_denoising()` in `burstphoto/denoise.swift` orchestrates: convert → load → pick reference → dispatch to one of three merge paths.
- Both merge paths (`spatial.swift`, `frequency.swift`) call, per comparison frame:
  `align_texture(ref_pyramid, comp_texture, ...)` which internally builds the alignment and then **discards it** — only the warped texture is returned.
- The alignment artifact is `current_alignment`: an `.rg16Sint` texture, one texel per tile, storing `(dx, dy)` in **pyramid-level-0 pixels** (level 0 = image downscaled by `mosaic_pattern_width`).
  - Sensor-pixel shift = `texel * downscale_factor_array[0]` (= `mosaic_pattern_width`, 2 for Bayer) — exactly what `warp_texture()` does.
  - Tile grid: tiles of `tile_size_array[0]` (default 32) with 50% overlap → grid pitch = `tile_size/2` level-0 px.
- All intermediate textures use `.storageMode = .private`; nothing in the app converts an `MTLTexture` to an `NSImage` today.
- Reusable existing helpers: `color_difference()` (per-superpixel SAD between two r32Float textures), `upsample()`, `blur()`, `convert_to_rgba()` (naive Bayer→RGBA at half res), `crop_texture()`.
- UI: one fixed 360×400 non-resizable window driven by an `AppState` machine (`main | processing | image_saved`) in `ContentView.swift`.
- Xcode project is objectVersion 54 → **new files must be added to `project.pbxproj`** (via Xcode or manual edit).

---

## Design overview

```
drop burst ──> perform_alignment_inspection()          (new: align-only pass)
                  │  per frame: AlignmentOutput { alignment tex, tile_info }
                  │            + ref/aligned textures retained in a session
                  ▼
          InspectionSession (ObservableObject)
                  │  on-demand render (Metal kernels → NSImage)
                  ▼
          AlignmentInspectorView (separate resizable window)
                  │  user picks frame / mode / gain
                  ▼
          [Merge] button ──> perform_denoising() ──> existing saved-image flow
```

Key decisions:
- **New align-only entry point** rather than a flag threaded through `perform_denoising` — keeps the production path untouched.
- **Refactor `align_texture` to also return the alignment texture** (compat wrapper keeps existing call sites unchanged).
- **Render heavy images on demand** for the selected frame only; keep small artifacts (alignment textures ≈ 150 KB/frame, stats) for all frames. This avoids N × full-res float textures staying resident.
- **Separate resizable window** for the inspector; the main window is fixed-size/hidden-titlebar and stays as-is.

---

## Phase 1 — expose alignment data from `align_texture`

**File: `burstphoto/align/align.swift`**

```swift
struct AlignmentOutput {
    let aligned_texture: MTLTexture     // warped comp texture (as returned today)
    let alignment_texture: MTLTexture   // rg16Sint tile-grid (dx, dy) in level-0 px
    let tile_info: TileInfo             // final-level tile geometry
    let downscale_factor: Int           // downscale_factor_array[0]
}

func align_texture_ex(...) -> AlignmentOutput   // current body, returns struct
func align_texture(...) -> MTLTexture           // thin wrapper, returns .aligned_texture
```
- Callers in `spatial.swift` (~L158) and `frequency.swift` (~L158) keep working unchanged.
- Document the units in a comment (level-0 px vs sensor px, tile pitch = `tile_size/2`).

## Phase 2 — visualization kernels

**New file: `burstphoto/viz/visualize.metal`** (+ shared include of `../misc/constants.h`)

1. `render_alignment_color` — reads the rg16Sint alignment texture, writes an `.rgba8Unorm` image at (configurable) preview resolution.
   - Per output pixel: map to tile-grid coords exactly like `warp_texture_bayer` does (`x_grid = (x+0.5)/half_tile - 1`), optionally **bilinear-interpolate** the 4 neighboring `(dx,dy)` (smooth field) or take nearest (blocky tile look — nice default, shows the actual tile grid).
   - Two color mappings (runtime-selected int flag):
     - **RGB axes**: `R = 0.5 + 0.5·dx/scale`, `G = 0.5 + 0.5·dy/scale`, `B = 0` → zero shift = 50% gray; red = +X, green = +Y.
     - **HSV flow**: hue = `atan2(dy, dx)`, value = `clamp(|shift|/scale)` → classic optical-flow look.
   - `scale` (px) passed as buffer arg (see auto-scaling below). Optional tile-grid line overlay flag.
2. `abs_difference` — `out = abs(ref - aligned)` on r32Float prepared (black-level-corrected, exposure-equalized) textures, full mosaic resolution.
3. `difference_to_rgba8` — tone-map the diff to 8-bit with a `gain` uniform and optional false-color LUT (gray default, "turbo" optional). Blur input first (reuse existing `blur()` with kernel 16, same trick as `robust_merge`) so users see motion/occlusion structure instead of shot noise.
4. `mosaic_to_rgba8` — generic tonemapped preview of a single r32Float mosaic texture (for showing reference / aligned candidate frames; grayscale fallback for non-Bayer, `convert_to_rgba` for Bayer).

## Phase 3 — Swift visualization helpers

**New file: `burstphoto/viz/visualize.swift`**

- `let render_alignment_color_state = create_pipeline(...)` etc. (follows existing top-level pattern).
- `alignment_stats(_ alignment: MTLTexture) -> (min_dx, max_dx, min_dy, max_dy, mean_mag)` — blit the small tile-grid texture to a shared buffer, scan on CPU (cheap: ~10⁵ texels). Used to auto-scale the color mapping and to show numeric readouts.
- `render_alignment_image(alignment, tile_info, downscale, preview_size, mode, auto_scale) -> NSImage`
- `render_difference_image(ref, aligned, gain, blur, colormap, preview_size) -> NSImage`
- `render_preview_image(texture, ...) -> NSImage`
- Texture→NSImage pattern: kernels write into `.rgba8Unorm` + `.storageModeShared` → `getBytes` → `NSBitmapImageRep` → `NSImage`. All callable off the main thread.

## Phase 4 — inspection pipeline

**New file: `burstphoto/inspect/inspect.swift`** (keeps `denoise.swift` focused)

```swift
class InspectionFrame: Identifiable {
    let url: URL
    let alignment: MTLTexture        // small, retained
    let tile_info: TileInfo
    let downscale_factor: Int
    let stats: AlignmentStats
    // rendered NSImages cached lazily (LRU depth ~3, one per mode)
}

class InspectionSession: ObservableObject {
    @Published var frames: [InspectionFrame]
    let ref_idx: Int
    // retained for on-demand rendering:
    let ref_texture_cropped: MTLTexture        // r32Float
    let comp_textures: [MTLTexture]            // prepared r32Float (already in memory post-load anyway)
    func image(for frame: InspectionFrame, mode: InspectMode, gain: Double) -> NSImage
}
```

`func perform_alignment_inspection(image_urls:, progress:, tile_size:, search_distance:, ...) throws -> InspectionSession`
- Reuses from `perform_denoising`: format checks, DNG conversion, `load_images`, reference selection (extract this shared prologue into a helper, e.g. `load_and_prepare_burst(...)`, and have `perform_denoising` call it too — avoids drift).
- Mirrors `align_merge_spatial_domain`'s padding/pyramid setup (`pad_align_x/y`, `downscale_factor_array`, ...); loop over frames calling `align_texture_ex`, store alignment outputs, **skip all merging**.
- Alignment settings: use the *spatial* path's parameters (frequency alignment is identical; only merge differs).
- Progress: reuse `ProcessingProgress` ranges ("Aligning images…", reuse the 20M–100M band proportionally).
- Non-Bayer: supported for the alignment field (units differ via `downscale_factor`); diff/preview fall back to grayscale mosaic rendering.

## Phase 5 — UI

**Files: `burstphoto/ContentView.swift`, `burstphoto/App.swift`**

- Add `.inspecting` to `AppState`; new `AlignmentInspectorView(session:)`:
  - Left sidebar: frame list (name + tiny alignment thumbnail, reference frame marked).
  - Center: zoomable/pannable image — `ScrollView` + `MagnificationGesture`, or an `NSImageView` wrapper for large images.
  - Mode picker (segmented): **Alignment | Difference | Warped candidate | Reference**.
  - Alignment controls: RGB/flow color mode, auto-scale vs manual ±px scale, tile-grid overlay toggle, legend (colored arrow/wheel).
  - Difference controls: gain slider, blur toggle, colormap picker.
  - Stats line: per-frame mean/max shift in sensor px, mean abs diff.
  - Buttons: **Merge** → continue into `perform_denoising` → existing `.image_saved` flow; **Back** → discard session.
- `App.swift`: second scene `Window("Alignment Inspector", id: "inspector")` (resizable); opened with `openWindow(id:)` when the session is ready. The app already gates macOS 13/14 APIs, so this is consistent. (Alternative if a second window is unwanted: swap in-window and grow `.frame` — rejected because the main window is deliberately fixed-size.)
- Entry point: preference checkbox **"Inspect alignment before merging"** (`@AppStorage` in `AppSettings` + a row in `SettingsView`), checked in `MyDropDelegate.performDrop`. Dev-friendly default for local builds: on.

## Phase 6 — CLI support (optional but cheap, great for testing)

**File: `burstphoto/cli.swift`** — add an inspection mode that dumps `alignment_{i}.png` and `diff_{i}.png` next to the output DNG. Enables headless verification of Phases 1–4 before any UI work.

---

## Testing plan

1. **Synthetic ground truth**: take one DNG, produce shifted copies (±3 px, diagonal) in the burst; verify the alignment field reports ≈ the known shift and the diff image collapses to ≈ noise after warping.
2. **Real bursts**: handheld night burst (small jitter → mostly-gray field), panning burst (smooth gradient field), scene with moving subject (localized bright regions in diff → demonstrates why robust merge downweights them).
3. **Memory/perf**: 50-frame 60 MP burst — confirm session retains only small alignment textures + inputs; on-demand warp+render of selected frame < ~100 ms.
4. **Regression**: `align_texture` wrapper change must leave merge outputs bit-identical (run CLI merge before/after Phase 1).

## Suggested implementation order

| Step | Deliverable | Verifiable by |
|---|---|---|
| 1 | Phase 1 refactor | CLI merge regression (bit-identical output) |
| 2 | Phases 2–3 + CLI dump (Phase 6) | synthetic-shift test |
| 3 | Phase 4 session | CLI inspection run on real burst |
| 4 | Phase 5 UI | manual use |

## File-change summary

- Modify: `align/align.swift`, `merge/spatial.swift` + `merge/frequency.swift` (if adopting new signature directly), `ContentView.swift`, `App.swift`, `cli.swift`, `denoise.swift` (shared prologue extraction)
- Add: `viz/visualize.metal`, `viz/visualize.swift`, `inspect/inspect.swift`
- All new files must be registered in `burstphoto.xcodeproj/project.pbxproj`

## Open questions

1. Inspector always shown, or preference-gated (plan assumes gated, default on for dev)?
2. Alignment field default look: blocky per-tile (honest) vs bilinear-smooth (prettier)? Plan defaults to blocky with a toggle.
3. Auto-scale the color range per burst (max |shift| observed) vs fixed ±4 px? Plan: auto, with manual override.
4. Should **Merge** reuse the already-computed alignments to skip re-alignment? (Possible later optimization; the `last_texture` cache doesn't cover this today.)
