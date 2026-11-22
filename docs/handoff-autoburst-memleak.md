# Handoff: auto-stacking feature + memory-leak investigation (2026-11-02, evening update)

Context for a fresh agent: this file summarizes (1) the memory leak in the alignment inspection
pipeline — now **RESOLVED: root cause found and fixed** (see §1), (2) the completed auto-stacking
/ stack-record feature work, and (3) how to build and test this project on this machine. Read
fully before continuing.

---

## 0. Files accidentally deleted from ~/Pictures/Burst Photo — RESOLVED (mostly)

An earlier session accidentally deleted ~35 of the user's manually created merged outputs
(files with mtime ≥ Nov 2 ~15:50). **The user restored them from a backup**: ~/Pictures/Burst
Photo now contains 418 `... (from backup).dng` files and the lost filenames verify as present,
EXCEPT three secondary outputs that remain missing in any naming variant:

- `DSC_0963_merged_q22_l0_raw-denoise.dng`
- `DSC_0963_merged_q22_l0_denoise.tif`
- `DSC_4565_merged_q22_l0 copy.dng`

All three are regenerable from the card (`/Volumes/NIKON Z6_3 /22_25_14/114NZ6_3`,
higher-quality algorithm, NR 22) if the user wants them — ask before spending the time. No
source RAWs were ever harmed (all NEFs are safe on the camera card).

---

## 1. Memory leak in the inspection pipeline — RESOLVED (root cause: closure capture)

### Symptom (historical)
Processing the full camera card (1666 NEFs → 31 bursts) with the `autoburst` CLI command got
OOM-killed mid-run:

```
log show --last 25m --predicate 'sender == "kernel" AND eventMessage CONTAINS[i] "memorystatus" AND eventMessage CONTAINS "burstphoto"'
→ memorystatus: killing largest compressed process burstphoto-cli [46463] 62611 MB
```
(Machine: 24 GB RAM, 10 cores. Run 3 got through 19 bursts before dying.)

### Root cause
The GUI progress-update closures captured the **whole `textures` array** (all full-res input
MTLTextures of a burst), e.g.:

```swift
DispatchQueue.main.async { progress.int += Int(80000000/Double(textures.count)) }
```

The CLI has **no runloop**, so the main `DispatchQueue` never drains: every queued block pins
every input texture of its pass until process exit. Growth ≈ 48.7 MB (one input texture,
6048×4024 r16Uint) + ~5% Metal overhead per frame per inspection. This explains every earlier
observation:

- leak scales per image (2-image burst ≈ +103 MB/pass, 4-image ≈ +206 MB/pass, seen in BOTH
  phys_footprint and `device.currentAllocatedSize` — the GPU resources really stay alive);
- `/usr/bin/leaks` reported nothing (the queued blocks are *reachable*, not leaked);
- autorelease pools had no effect (retention is via the queue, not a pool — verified
  empirically with pooled vs. plain memtest phases; the earlier "prime suspect" is dead);
- load-only phases were flat (`load_and_prepare_burst` is called with `progress: nil` there);
- the merge phase looked flat in isolation only because `perform_denoising`'s `last_texture`/
  `last_settings` result cache skips re-merging identical inputs — the one-time +305 MB gpu
  jump at merge pass 0 was the same leak firing once (and `current_settings` includes the
  input URLs, so real autoburst runs bypass that cache and pile up merge closures too);
- the GUI never showed it: its runloop drains the main queue continuously;
- full-card OOM at 62.6 GB after ~19 bursts ≈ ~1000 processed frames × ~48.7 MB retained +
  working set.

### Fix (all uncommitted)
Hoist the count computation into a local `Int` so the closures capture only a scalar:

- `burstphoto/inspect/inspect.swift` — 2 sites (ref frame + comparison frames in
  `perform_alignment_inspection`), hoisted as `progress_units_per_frame` before the frame loop;
- `burstphoto/merge/spatial.swift` — 2 sites in `align_merge_spatial_domain` (same hoist);
- `burstphoto/merge/frequency.swift` — 1 site in `align_merge_frequency_domain` (inline hoist,
  `4*(textures.count-1)`);
- `burstphoto/denoise.swift` — 2 sites in `calculate_temporal_average` (hoisted before the
  branch containing the loops);
- `burstphoto/burst/autoburst.swift` — hygiene: hoisted `n_bursts` so the per-burst
  `status_line` closures don't capture the `stackable` URL arrays (KBs, but same pattern).

Semantically null (the count is computed at enqueue time either way). Selftest passes; CLI and
GUI rebuild clean.

### Verification evidence
- `memtest` (4-frame burst): leaky build `inspect-plain` = +206 MB/pass (gpu +206 MB/pass);
  fixed build = +0.6 MB/pass (noise level) over the passes that ran before an unrelated
  `.dngs` wipe (see footgun in §4). Autorelease-pool wrapping made no difference, eliminating
  the earlier prime suspect.
- End-to-end `autoburst /tmp/leaktest` (3 bursts, 115 frames, includes real inspections AND
  real merges): 3/3 merged, sidecars written, footprint 32 → 6113 → 7476 → 5003 MB
  (non-monotonic → no compounding retention).
- Full-card run (2026-11-02 evening, fixed binary, ~13 min wall for 1666 NEFs / 31 bursts):
  **exit 0, no kernel memorystatus kill**. Result: 29/31 merged · 927 frames rejected · 1
  skipped (no match) · 1 failed (burst 29) · 5 single images. 29 outputs + sidecars written.
  Per-burst start footprint ratcheted 110 MB → ~30 GB over the run (see note below) while the
  leaky build was killed at 62.6 GB after 19 bursts.
- Burst 29 failure root-caused: the **last 6 frames of the burst (DSC_4006–4011) are corrupt on
  the card** — Adobe DNG Converter refuses all six ("Failed to convert", deterministic,
  verified one-by-one), while every other frame of the card converts fine. A contiguous run of
  interrupted writes at the burst's tail. Worked around by merging the remaining 42 frames
  (`autoburst` on the good file list); quality impact negligible (the pipeline rejects frames
  routinely anyway). Note: `convert_raws_to_dngs` throws on the FIRST missing conversion, so
  with multiple bad frames only the first gets reported per burst — the single-file scan was
  needed to see the full extent.
- **Residual footprint ratchet (NOT the fixed leak)**: under sustained multi-burst load the
  process phys_footprint climbs to ~30 GB (swell via driver pools/compressed pages; swap hit
  ~12 GB, system survived). memtest proves the closure leak itself is gone (flat per pass,
  plateau self-reclaims after ~60 s idle); under continuous load the reclaim never gets a
  chance. If this ever matters in practice: process bursts in chunks / re-exec periodically,
  or investigate Metal deferred-free behavior. Machine returned to 81% free after the run.
- Known pre-existing (unrelated to the leak): Adobe DNG Converter prints ~58
  `*** Error: NewRawImageDigest does not match raw image ***` warnings when re-verifying the
  DNGs our writer produces in the save path — outputs are still written and valid; the writer's
  digest computation appears wrong (cosmetic/noisy, worth its own fix someday).
- Burst 29 (corrupt-tail burst): merged from its 42 good frames → `DSC_3964_merged_f13_l0.dng`
  + sidecar (27 frames score-rejected, 15 averaged). **Final card tally: 30 of 31 bursts
  merged with sidecars; 1 burst skipped by design (no frame matched); 3 orphan DNGs from older
  manual experiments remain (no sidecars, untouched).**
- Orphans found during verification: `DSC_6132/6133/6351_merged_f13_l0.dng` in
  ~/Pictures/Burst Photo have no sidecars; their frames are not part of any detected card burst
  (earlier manual experiments; sidecars likely lost in the §0 deletion). Left untouched.

### If footprints ever grow again
`memtest` now reports both `phys_footprint` and `device.currentAllocatedSize` per pass: growing
gpu = resources still referenced (hunt retainers); flat gpu but growing footprint =
driver/pool behavior. Memtest phases now PRINT failures instead of silent `try?` no-ops. The
transient ~350–475 MB plateau right after the first inspection pass is normal and
self-reclaims after ~60 s idle.

---

## 2. Feature work completed this session (all uncommitted!)

### Auto-stacking pipeline (burstphoto/burst/autoburst.swift — new file)
- `read_capture_timestamp` / `read_capture_timestamps`: EXIF `DateTimeOriginal` +
  `SubsecTimeOriginal` (sub-second) via ImageIO/CGImageSource, read in parallel. NOTE: the
  constants are spelled `kCGImagePropertyExifSubsecTimeOriginal` (lower-case "sec").
- `collect_raw_urls`: expands dirs (non-recursive), filters `raw_extensions`
  (["dng","nef","cr2","cr3","arw","orf","rw2","raf"] — global, reused by cli inspect).
- `split_into_bursts(urls:timestamps:max_gap:)`: sort by (time, path); new burst when gap >
  `auto_burst_max_gap` (1.0 s, i.e. exactly 1.0 s stays in the same burst).
- `perform_auto_burst_processing(...)`: per burst (groups of ≥2): `perform_alignment_inspection`
  → score each comparison frame with `frame_alignment_score` (=
  `alignment_variation_in_roi` inside `auto_burst_subject_roi`) → reject score >
  `auto_burst_max_alignment_score` (10.0, pyramid level-0 px) → if only the reference survives,
  skip the burst → else `perform_denoising` on survivors. Per-burst errors recorded, not fatal
  (except `missing_dng_converter`). DNG preferred when a burst mixes DNG+RAW (printed).
  Returns `AutoBurstResult` (merged_urls, records, counts, summary string).
- If the user ever wants the difference-based score instead of alignment variation, the
  "diff" score lives in InspectorModel (`roi_scores`); `frame_alignment_score` is the switch point.

### Stack record sidecars (burstphoto/burst/stack_record.swift — new file)
- `StackRecord: Codable`: schema_version (1), app_version, created_at, output_file,
  initial_files, selected_files, merging_algorithm, tile_size, search_distance,
  noise_reduction, exposure_control (short name), output_bit_depth (short name).
  Helpers: output_url/initial_urls/selected_urls/sidecar_url (output path with .json).
- `save_stack_record` (pretty JSON, ISO8601), `load_stack_record` (validates version and ≥2
  selected files), `app_version_string()`.
- `perform_denoising` (denoise.swift) now takes `initial_image_urls: [URL]? = nil` and returns
  `(out_url: URL, record: StackRecord)`; it writes the sidecar itself (with the *effective*
  settings after non-Bayer downgrades) at the very end. JSON write failure = printed warning,
  merge still succeeds. All call sites updated (cli, autoburst, ContentView).

### GUI (ContentView.swift, AlignmentInspectorView.swift)
- Main screen has **two drop zones**: classic (`MyDropDelegate`, stacks everything) and
  "Auto-detect bursts" (`AutoBurstDropDelegate`). Both accept a dropped `.json` stack file →
  `open_stack_files(...)` loads the record, runs `perform_alignment_inspection` on the existing
  initial frames, and opens the **alignment inspector** with previously-deselected frames
  pre-unchecked (rejected frames can be re-checked). Settings are adjusted via the normal
  Preferences window; the "image saved" screen has "Show in Finder" + "Settings…" buttons
  (`open_preferences_window()`; `SettingsButton` refactored to use it). (The user explicitly
  rejected an earlier design that inlined all settings into the saved screen — do not reintroduce.)
- `InspectionCoordinator`: `show(session:initial_urls:initially_excluded_urls:)`,
  `stack_initial_urls`, `initially_excluded_urls`; `dismiss()` clears them. Merge button passes
  (initial, selected) where initial = `stack_initial_urls ?? session frames` so re-merges keep
  the recorded initial history. `merge_handler: (([URL], [URL]) -> Void)?` (no arg labels —
  Swift function types can't have them).
- `ContentView.run_merge(initial_urls:selected_urls:)`; multi-burst progress via
  `ProcessingProgress.phase_total` + `status_line` (new fields; `progress_units_per_burst` =
  110_000_000 in denoise.swift). `ProcessingView` derives per-burst phase text from
  `int % per_burst` with boundary-preserving mapping.
- `ImageSavedView(stacks:summary:drop_active:)` — stacks = [StackRecord]; shows
  "Merged X of Y images · <name>" or the run summary.

### Scoring/ROI refactor (inspect/inspect.swift)
- `RoiRect` struct moved here from AlignmentInspectorView.swift (CLI target needs it).
- `af_subject_roi(session:)` (AF point doubled, min 4% of frame) and
  `auto_burst_subject_roi(session:)` (AF ROI or centered 50%×50% fallback).
- `alignment_variation_in_roi(texels:alignment_width:alignment_height:tile_size:
  downscale_factor:roi:frame_width:frame_height:pad_x:pad_y:)` — extracted from InspectorModel;
  `InspectorModel.alignment_variation` and the inspector default ROI now delegate to these.
- `median_of_sorted` is a global in inspect.swift now (was private in the view file).

### CLI (cli.swift)
- `autoburst <paths...> [--gap s] [--max-score px] [--tile|--search|--nr n|--hq]` — the
  end-to-end pipeline; prints per-frame kept/rejected scores and a summary.
- `stackinfo <file.json>...` — dumps a sidecar.
- `memtest <files...>` — leak bisection harness (see §1/§4). Phases: load ×5, load(cache) ×5,
  inspect-with-progress ×10, inspect-nil-progress ×10, merge ×4 (alternating `--nr` 13/14 to
  bypass the `last_texture` settings cache so every pass really merges). Reports
  phys_footprint AND gpu (`device.currentAllocatedSize`) per pass; failures are printed, not
  swallowed.
- Usage comment at top of cli.swift updated. README features list updated.

### Project plumbing
- New files must be added in THREE places: `burstphoto.xcodeproj/project.pbxproj` (PBXBuildFile
  for BOTH targets "gui" and "cli", PBXFileReference, PBXGroup "burst", both Sources phases) —
  fake-ID scheme `FAC0DE0A00000000000000XX`, used so far: A1,A2,B1–B5,C1–C8,D1–D7; next free D8.
  AND `build_cli_manual.sh` AND `build_gui_manual.sh` SWIFT_SRCS lists.
- pbxproj still lints clean (`plutil -lint`).

---

## 3. Build quick reference

`xcodebuild` is broken on this machine — use the manual scripts (both worked all session):

```bash
./build_cli_manual.sh    # builds build_manual/cli.app/Contents/MacOS/burstphoto-cli (also (re)compiles dng_sdk C++ into build_manual/obj; a few minutes)
./build_gui_manual.sh    # builds build_manual/burstphoto.app — REQUIRES build_cli_manual.sh to have run once (reuses its .o files)
```

Fast iteration without linking (seconds):
```bash
# CLI target:
swiftc -typecheck -swift-version 5 -target arm64-apple-macos11.0 \
  -import-objc-header burstphoto/io_dng/bridging_header.h \
  -Idng_sdk/dng_sdk -Idng_sdk/libjpeg -Idng_sdk/xmp_headers -Iburstphoto/io_dng \
  burstphoto/cli.swift burstphoto/denoise.swift burstphoto/align/align.swift \
  burstphoto/burst/autoburst.swift burstphoto/burst/stack_record.swift \
  burstphoto/merge/spatial.swift burstphoto/merge/frequency.swift burstphoto/texture/texture.swift \
  burstphoto/exposure/exposure.swift burstphoto/io_dng/io_dng_sdk.swift burstphoto/misc/helpers.swift \
  burstphoto/misc/selftest.swift burstphoto/viz/visualize.swift burstphoto/inspect/inspect.swift

# GUI target: same but sources = burstphoto/App.swift burstphoto/ContentView.swift
#   burstphoto/inspect/AlignmentInspectorView.swift (+ all of the above EXCEPT cli.swift and selftest.swift)
```
(swift-version 5, deployment target macOS 11.0 — avoid newer APIs; e.g. no `openWindow`, no
Swift-concurrency-only features, `SettingsLink` needs an `if #available(macOS 14)` fallback.)

**Do not edit Swift files while a build script is running** — swiftc aborts with
"input file was modified during the build".

---

## 4. Test quick reference

### Built-in selftest (no input files needed; covers alignment, visualization, brightness
matching, EXIF parsing, burst grouping, stack-record round trip)
```bash
./build_manual/cli.app/Contents/MacOS/burstphoto-cli selftest
```

### Test data on this machine
- `/Volumes/NIKON Z6_3 /22_25_14/114NZ6_3` — **NOTE trailing space in "NIKON Z6_3 "** —
  1666 NEFs, 58 MOV, 1 DAT; 31 bursts (4–238 frames, ~0.08 s apart) + 5 single images.
- `~/Pictures/owl` — 5 NEFs; only DSC_4552+4553 form a burst (0.42 s apart; score 11.37 →
  rejected at default threshold 10; use `--max-score 20` to see a merge).
- `~/Pictures/Comet c-2025 atlas/lights` — frames 6 s apart (use `--gap 10`).
- ~~`/tmp/leaktest` — 115 NEFs copied from the card for the leak work~~ — **deleted** (2026-11-02
  evening, after the leak was fixed; originals are on the card).

### Typical invocations
```bash
CLI=./build_manual/cli.app/Contents/MacOS/burstphoto-cli
$CLI autoburst "/Volumes/NIKON Z6_3 /22_25_14/114NZ6_3"        # full card (~1.5–2.5 h)
$CLI autoburst <dir-or-files> --gap 10 --max-score 20 --hq --nr 22   # option knobs
$CLI stackinfo ~/Pictures/Burst\ Photo/DSC_3279_merged_f13_l0.json
$CLI memtest <2-4 NEFs>      # leak harness; watch "inspect-plain" lines (should be FLAT now)
$CLI inspect <burst_dir>     # pre-existing visualization mode
$CLI afinfo <file.nef>       # AF area parsing check
```

### Monitoring / forensics
```bash
# OOM kill evidence
log show --last 25m --predicate 'sender == "kernel" AND eventMessage CONTAINS[i] "memorystatus" AND eventMessage CONTAINS "burstphoto"'
df -h /System/Volumes/Data   # disk headroom during full-card runs
```

### ⚠ Footgun: the GUI wipes the shared tmp DNG cache
`App.swift` deletes `~/Pictures/Burst Photo/.dngs/` **on GUI launch AND on quit**. Launching or
quitting the GUI while a CLI `autoburst`/`memtest` run is active destroys its converted DNGs
mid-run (conversion then fails; memtest used to swallow this silently — it now prints
failures). Never launch/quit the GUI during a CLI run.

### GUI smoke test
```bash
pgrep -fl burstphoto               # check the user doesn't have their own instance running first
open -n build_manual/burstphoto.app   # -n is important: a plain `open` may just foreground an
                                      # instance the USER started themselves (this bit us once)
sleep 4; pgrep -fl burstphoto; ps aux | grep "[b]uild_manual/burstphoto.app"
osascript -e 'tell application "burstphoto" to quit'
```
(The manual build and the user's installed app are both named "burstphoto"; verify by path in
ps output. Last smoke test: 2026-11-02 evening, PASS.)

---

## 5. Leftovers / housekeeping

- **All session work is uncommitted** (git status: modified README.md, project.pbxproj,
  ContentView.swift, cli.swift, denoise.swift, AlignmentInspectorView.swift, inspect.swift,
  selftest.swift, io_dng_sdk.swift, build scripts, spatial.swift, frequency.swift; new
  burstphoto/burst/*, docs/*). A checkpoint commit is advisable now that the leak is fixed.
- ~/Pictures/Burst Photo contains: run-3's 19 `*_f13_l0.dng/.json` pairs, three fresh
  leaktest-validated outputs (`DSC_3279/3334/3399_merged_f13_l0.dng/.json`, written by the
  fixed binary), the user's restored library, and `.dngs/` (auto-managed tmp cache; also
  auto-deleted by GUI launches).
- Disk: Data volume 97% full, ~31 GB free. The tmp DNG cache self-caps at
  `min(10 GB, 15% of *free disk space*, …)` per merge (denoise.swift `maxDNGFolderSizeGB` /
  `trim_disk_cache`), so a full-card run peaks around ~5 GB cache + ~13 GB largest-burst
  conversions + ~1 GB outputs. Still, keep an eye on `df` during long runs.
- Long-term idea mentioned but not implemented: chunking/capping very large bursts (238 frames
  ≈ 12 GB live textures) — only relevant if OOMs persist (they shouldn't, with the leak fixed).
