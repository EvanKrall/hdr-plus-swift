/**
 Alignment inspector window: interactive pre-merge visualization of the alignment fields and
 difference images of a burst (see inspect/inspect.swift for the underlying InspectionSession).

 The window is created as a plain NSWindow (not a SwiftUI Window scene) so that it also works on
 the app's minimum deployment target (macOS 11), where openWindow(id:) is unavailable.

 Design notes:
 - All heavy rendering (warp, difference, tonemap) happens on demand for the selected frame only,
   on a background thread; stale renders are dropped via a generation counter.
 - The alignment color scale (saturation point) and the difference white point are SHARED ACROSS
   ALL FRAMES of a burst (median-based, identical to the CLI in cli.swift), so that images are
   comparable between frames. The shared difference white point requires a measurement pass over
   all frames; until it completes, difference renders fall back to a per-frame scale.
 - The calibration pass also retains tiny downsampled copies (48 px on the long side) of every
   frame's warped and difference data, from which the frame-list thumbnails are tonemapped on the
   CPU — so thumbnails follow the selected visualization mode without re-rendering full frames.
 - Clicking the image sets an ANCHOR POINT (in reference/warped coordinates). All alignment and
   flow visualizations (main view and thumbnails) subtract the shift of the anchored tile of their
   own frame, so the anchor becomes zero and the field shows the deformation RELATIVE to it. When
   an anchor is set, the Difference tab fits the brightness match locally and robustly around it
   (maximizing the number of pixels with approximately zero difference) instead of using the
   global least-squares fit.
 - The Difference tab maps the SIGNED difference to color: warped brighter than the reference is
   red, warped darker is blue, equality is black.
 - The frame list supports checking/unchecking images (excluded from the merge), and multi-
   selection with cmd-click (toggle one) and shift-click (toggle a range). Checking/unchecking a
   row of a multi-selection applies to all selected rows.
 - Up/down arrow keys select the previous/next frame.
 */
import SwiftUI
import AppKit
import Combine


/// Visualization modes of the inspector window.
enum InspectMode: String, CaseIterable, Identifiable {
    case alignment  = "Alignment"   // per-tile shift, R = +x, G = +y, zero = 50% gray
    case flow       = "Flow"        // per-tile shift, hue = direction, brightness = magnitude
    case difference = "Difference"  // signed reference - warped candidate, brightness-matched
    case original   = "Original"    // unwarped frame (shifted to the anchor if one is set)
    case warped     = "Warped"      // warped candidate frame
    case reference  = "Reference"   // reference frame
    
    var id: String { rawValue }
    var is_alignment: Bool { self == .alignment || self == .flow }
}


/// A user-selected anchor point: fractional position in the frame plus the tile grid cell under it.
struct AnchorPoint: Equatable {
    var u: CGFloat
    var v: CGFloat
    var tile_x: Int
    var tile_y: Int
}


/// A user-dragged rectangular "subject" area, as fractions of the frame (origin top-left). Used
/// to score each frame by its similarity to the reference inside that area.
struct RoiRect: Equatable {
    var x0: CGFloat
    var y0: CGFloat
    var x1: CGFloat
    var y1: CGFloat

    func normalized() -> RoiRect {
        RoiRect(x0: min(x0, x1), y0: min(y0, y1), x1: max(x0, x1), y1: max(y0, y1))
    }

    var is_degenerate: Bool { abs(x1 - x0) * abs(y1 - y0) < 0.0005 }
}


/// Owns the inspection session and the inspector window. Shared between the main window
/// (which creates sessions when a burst is dropped) and the inspector window.
final class InspectionCoordinator: ObservableObject {
    @Published var session: InspectionSession?
    var window: NSWindow?
    /// Installed by ContentView: starts the regular merge for the given image urls.
    var merge_handler: (([URL]) -> Void)?
    
    /// Show the inspector window for the given session (reuses an existing window).
    func show(session: InspectionSession) {
        self.session = session
        if let window = window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Alignment Inspector"
            window.minSize = NSSize(width: 940, height: 580)
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AlignmentInspectorView(coordinator: self))
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    /// Hide the inspector window and release the session (frees the retained burst textures).
    func dismiss() {
        session = nil
        window?.orderOut(nil)
    }
}


/// Result of one background render: the image plus a human-readable summary of the exact
/// rendering parameters used (scale, white point, brightness match).
struct InspectorRenderResult {
    let bitmap: NSBitmapImageRep
    let info: String
}


/// State and background work of one inspector session (one burst).
final class InspectorModel: ObservableObject {
    let session: InspectionSession
    
    /// Shared alignment color scale (saturation point, level-0 pixels), computed from the
    /// per-frame alignment stats: 2 x median mean |shift|, capped by the burst's max shift.
    let alignment_scale: Int
    let median_mean_shift: Double
    let burst_max_shift: Int
    
    /// Shared difference white point (gain multiplier x median frame mean difference), measured
    /// in a background pass so that difference images are comparable between frames.
    @Published var calibrated = false
    @Published var calibration_progress = 0
    private(set) var median_diff_mean: Float = 0
    
    /// Small thumbnails for the frame list, following the selected visualization mode.
    private(set) var thumbnails: [Int: NSImage] = [:]
    @Published var thumbnails_version = 0

    /// Mean brightness-matched difference to the reference inside the user-selected subject area,
    /// per frame index (lower = more similar). Empty until an area is selected.
    @Published var roi_scores: [Int: Float] = [:]
    /// Variation of the tile alignment field inside the subject area (mean deviation of the tile
    /// shifts from the median tile shift, level-0 pixels; lower = cleaner/rigid mapping). Empty
    /// until an area is selected.
    @Published var roi_align_scores: [Int: Float] = [:]
    @Published var roi_scores_version = 0
    private var roi_scores_generation = 0
    
    /// Tiny downsampled copies of the warped / difference data of every frame (built during the
    /// calibration pass), used for CPU-side thumbnail tonemapping.
    struct Downsampled {
        var values: [Float]
        var width: Int
        var height: Int
    }
    struct FrameThumbnailData {
        var warped: Downsampled
        var warped_max: Float
        var diff: Downsampled
        var diff_mean: Float
        /// finer difference downsample (192 px long side) used for subject-area scores
        var diff_fine: Downsampled
    }
    private(set) var frame_data: [Int: FrameThumbnailData] = [:]
    private var ref_data: Downsampled?
    /// pooled pixel values of the reference frame (used for anchor-local brightness fits)
    private(set) var ref_pooled_values: [Float] = []
    private(set) var ref_pooled_width = 0
    private(set) var ref_pooled_height = 0
    
    /// Cached alignment texels per frame (small readbacks, used for anchor offsets).
    private var texel_cache: [Int: [Int16]] = [:]
    /// Cached all-zero alignment field (used to visualize the reference frame's alignment).
    private var zero_alignment: MTLTexture?
    /// Brightest pooled pixel of the reference frame (used for warped/reference thumbnails).
    private(set) var ref_max: Float = 0
    
    private var background_started = false
    private var thumbs_generation = 0
    
    init(session: InspectionSession) {
        self.session = session
        let magnitudes = session.frames.compactMap { $0.stats?.mean_magnitude }.sorted()
        median_mean_shift = median_of_sorted(magnitudes)
        burst_max_shift = session.frames.compactMap { $0.stats?.max_abs_shift }.max() ?? 1
        alignment_scale = max(1, min(Int(median_mean_shift * 2.0), max(burst_max_shift, 1)))
    }
    
    /// Build the downsampled per-frame data (warped + difference), warm the session's brightness
    /// match cache and measure the shared difference scale. Idempotent.
    func start_background_work() {
        guard !background_started else { return }
        background_started = true
        let model = self
        DispatchQueue.global().async {
            // pooled reference values (shared by all brightness matches and the reference thumbnail)
            let ref_texture = model.session.ref_texture_cropped
            let (ref_values, ref_pool) = pooled_values(ref_texture, preferred_pool: 4)
            let ref_width = ref_texture.width / ref_pool
            let ref_height = ref_texture.height / ref_pool
            var ref_max: Float = 0
            for value in ref_values { ref_max = max(ref_max, value) }
            DispatchQueue.main.async { model.ref_max = ref_max }
            let ref_downsampled = downsample_values(ref_values, width: ref_width, height: ref_height)
            
            // reference thumbnail (also shown in the frame list's reference row)
            let ref_bitmap = gray_bitmap_from_values(ref_downsampled.values, width: ref_downsampled.width,
                                                     height: ref_downsampled.height, white_point: max(ref_max, 1e-6))
            let comparison_frames = model.session.frames.filter { !$0.is_reference }
            var means: [Float] = []
            
            for (n, frame) in comparison_frames.enumerated() {
                // pooled values of the warped comparison texture (single GPU render + readback)
                let aligned = model.session.aligned_texture(for: frame.index)
                let (values, pool) = pooled_values(aligned, preferred_pool: 4)
                let width = aligned.width / pool
                let height = aligned.height / pool
                var warped_max: Float = 0
                for value in values { warped_max = max(warped_max, value) }
                
                // brightness match and per-pixel difference, computed on the pooled values
                let match = brightness_match_values(ref_values, values)
                var diff_values = [Float](repeating: 0.0, count: values.count)
                var diff_sum = 0.0
                for i in 0..<values.count {
                    let d = abs(ref_values[i] - (match.gain * values[i] + match.offset))
                    diff_values[i] = d
                    diff_sum += Double(d)
                }
                let warped_ds = downsample_values(values, width: width, height: height)
                let diff_ds = downsample_values(diff_values, width: width, height: height)
                let diff_fine_ds = downsample_values(diff_values, width: width, height: height, target_long_side: 192)
                let data = FrameThumbnailData(
                    warped: Downsampled(values: warped_ds.values, width: warped_ds.width, height: warped_ds.height),
                    warped_max: warped_max,
                    diff: Downsampled(values: diff_ds.values, width: diff_ds.width, height: diff_ds.height),
                    diff_mean: Float(diff_sum / Double(values.count)),
                    diff_fine: Downsampled(values: diff_fine_ds.values, width: diff_fine_ds.width, height: diff_fine_ds.height))
                means.append(data.diff_mean)
                
                let progress = n + 1
                DispatchQueue.main.async {
                    model.frame_data[frame.index] = data
                    model.session.store_match(for: frame.index, gain: match.gain, offset: match.offset)
                    model.calibration_progress = progress
                }
            }
            
            let median = Float(median_of_sorted(means.map { Double($0) }))
            DispatchQueue.main.async {
                model.ref_data = Downsampled(values: ref_downsampled.values, width: ref_downsampled.width, height: ref_downsampled.height)
                model.ref_pooled_values = ref_values
                model.ref_pooled_width = ref_width
                model.ref_pooled_height = ref_height
                let ref_image = NSImage(size: NSSize(width: ref_bitmap.pixelsWide, height: ref_bitmap.pixelsHigh))
                ref_image.addRepresentation(ref_bitmap)
                if let ref_frame = model.session.frames.first(where: { $0.is_reference }) {
                    model.thumbnails[ref_frame.index] = ref_image
                }
                model.median_diff_mean = median
                model.calibrated = true
                model.thumbnails_version += 1
            }
        }
    }
    
    /// Regenerate the frame-list thumbnails for the given mode (background, progressive).
    /// Alignment/flow thumbnails are rendered on the GPU (with per-frame anchor offsets);
    /// difference/warped thumbnails are tonemapped on the CPU from the downsampled buffers.
    func regenerate_thumbnails(mode: InspectMode, align_scale: Int, anchor_tile: (x: Int, y: Int)?, diff_gain: Float) {
        thumbs_generation += 1
        let generation = thumbs_generation
        let model = self
        DispatchQueue.global().async {
            func publish(_ idx: Int, _ bitmap: NSBitmapImageRep) {
                DispatchQueue.main.async {
                    guard generation == model.thumbs_generation else { return }
                    let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                    image.addRepresentation(bitmap)
                    model.thumbnails[idx] = image
                    model.thumbnails_version += 1
                }
            }
            func publish_alignment_placeholder(_ idx: Int) {
                // alignment field of the frame as a stand-in until per-mode data exists
                guard let frame_at = model.session.frames.first(where: { $0.index == idx }),
                      let alignment = frame_at.alignment_texture ?? model.zero_alignment_texture() else { return }
                let bitmap = render_alignment_bitmap(alignment, color_mode: .hsv_flow, scale: model.alignment_scale, block_size: 1)
                publish(idx, bitmap)
            }
            switch mode {
            case .alignment, .flow:
                let color_mode: AlignmentColorMode = mode == .alignment ? .rgb_axes : .hsv_flow
                for frame in model.session.frames {
                    guard let alignment = frame.alignment_texture ?? model.zero_alignment_texture() else { continue }
                    let offset: [Float] = (anchor_tile != nil && !frame.is_reference)
                        ? model.alignment_offset(for: frame.index, tile_x: anchor_tile!.x, tile_y: anchor_tile!.y)
                        : [0.0, 0.0]
                    let bitmap = render_alignment_bitmap(alignment, color_mode: color_mode,
                                                         scale: align_scale, block_size: 1, offset: offset)
                    publish(frame.index, bitmap)
                }
            case .difference:
                for frame in model.session.frames {
                    if frame.is_reference {
                        // the reference differs from itself by zero -> uniform black thumbnail
                        if let d = model.ref_data {
                            publish(frame.index, gray_bitmap_from_values([Float](repeating: 0, count: d.width * d.height),
                                                                         width: d.width, height: d.height, white_point: 1))
                        }
                        continue
                    }
                    guard let data = model.frame_data[frame.index] else {
                        // calibration has not reached this frame yet: show the alignment field as a
                        // placeholder instead of an empty cell
                        publish_alignment_placeholder(frame.index)
                        continue
                    }
                    let white = (model.calibrated ? model.median_diff_mean : data.diff_mean) * diff_gain
                    let bitmap = gray_bitmap_from_values(data.diff.values, width: data.diff.width, height: data.diff.height,
                                                         white_point: max(white, 1e-6))
                    publish(frame.index, bitmap)
                }
            case .warped:
                for frame in model.session.frames {
                    if frame.is_reference {
                        // the warped reference frame is the reference frame itself
                        if let d = model.ref_data {
                            publish(frame.index, gray_bitmap_from_values(d.values, width: d.width, height: d.height,
                                                                         white_point: max(model.ref_max, 1e-6)))
                        }
                        continue
                    }
                    guard let data = model.frame_data[frame.index] else {
                        publish_alignment_placeholder(frame.index)
                        continue
                    }
                    let bitmap = gray_bitmap_from_values(data.warped.values, width: data.warped.width, height: data.warped.height,
                                                         white_point: max(data.warped_max, 1e-6))
                    publish(frame.index, bitmap)
                }
            case .original, .reference:
                break  // thumbnails keep the previous mode's appearance; the ref row always shows the ref preview
            }
        }
    }

    /// Mean brightness-matched absolute difference inside the selected subject area, per frame
    /// (lower = more similar to the reference). Computed from the 192-px difference downsample
    /// built during the calibration pass, as a plain mean (no outlier exclusion — locally bad
    /// regions are exactly what the score should reflect). Frames without calibration data yet
    /// are scored once their data arrives (the view re-calls this as calibration progresses).
    /// Also computes the alignment-variation score (see alignment_variation(idx:roi:)) for the
    /// same area; both maps are published together.
    func compute_roi_scores(roi: RoiRect?) {
        roi_scores_generation += 1
        let generation = roi_scores_generation
        let model = self
        DispatchQueue.global().async {
            var scores: [Int: Float] = [:]
            var align_scores: [Int: Float] = [:]
            if let roi = roi {
                let n = roi.normalized()
                for frame in model.session.frames where !frame.is_reference {
                    if let data = model.frame_data[frame.index] {
                        let d = data.diff_fine
                        let cx0 = min(d.width - 1, max(0, Int(floor(n.x0 * CGFloat(d.width)))))
                        let cx1 = max(cx0 + 1, min(d.width, Int(ceil(n.x1 * CGFloat(d.width)))))
                        let cy0 = min(d.height - 1, max(0, Int(floor(n.y0 * CGFloat(d.height)))))
                        let cy1 = max(cy0 + 1, min(d.height, Int(ceil(n.y1 * CGFloat(d.height)))))
                        var values: [Float] = []
                        values.reserveCapacity((cx1 - cx0) * (cy1 - cy0))
                        for y in cy0..<cy1 {
                            let row = y * d.width
                            for x in cx0..<cx1 { values.append(d.values[row + x]) }
                        }
                        if !values.isEmpty {
                            var sum = 0.0
                            for value in values { sum += Double(value) }
                            scores[frame.index] = Float(sum / Double(values.count))
                        }
                    }
                    if let variation = model.alignment_variation(idx: frame.index, roi: roi) {
                        align_scores[frame.index] = variation
                    }
                }
            }
            DispatchQueue.main.async {
                guard generation == model.roi_scores_generation else { return }
                model.roi_scores = scores
                model.roi_align_scores = align_scores
                model.roi_scores_version += 1
            }
        }
    }
    
    /// Variation of the tile alignment field inside a rectangle (fractions, y from top): each
    /// tile's shift is compared to the per-axis median shift of the region, combined to a
    /// magnitude, and averaged over all tiles in the region (no outlier exclusion — the
    /// worst-matching tiles are the signal). Only tiles fully inside the rectangle are used when
    /// there are at least four of them (boundary tiles mix subject and background motion);
    /// otherwise overlapping tiles are used. Returns the score in level-0 pixels (lower = more
    /// rigid mapping to the reference); nil if the rectangle is smaller than a few tiles or the
    /// frame has no alignment field.
    func alignment_variation(idx: Int, roi: RoiRect) -> Float? {
        let frame = session.frames[idx]
        guard let alignment = frame.alignment_texture, let tile_info = frame.tile_info else { return nil }
        let texels = alignment_texels(for: idx)
        guard texels.count >= alignment.width * alignment.height * 2 else { return nil }
        let n_tiles_x = alignment.width, n_tiles_y = alignment.height
        // tile geometry: the alignment grid spans the PADDED frame at 1/downscale scale; tile ix
        // centers at level-0 x = (ix + 1) * tile_size / 2 (see warp_texture_bayer). Frame pixels
        // therefore map to level-0 pixels as (x + pad) / downscale.
        let downscale = CGFloat(frame.downscale_factor)
        let half_tile = CGFloat(tile_info.tile_size) / 2
        let n = roi.normalized()
        let x0 = (n.x0 * CGFloat(session.ref_texture_cropped.width) + CGFloat(session.pad_x)) / downscale
        let x1 = (n.x1 * CGFloat(session.ref_texture_cropped.width) + CGFloat(session.pad_x)) / downscale
        let y0 = (n.y0 * CGFloat(session.ref_texture_cropped.height) + CGFloat(session.pad_y)) / downscale
        let y1 = (n.y1 * CGFloat(session.ref_texture_cropped.height) + CGFloat(session.pad_y)) / downscale
        
        var inner: [(Float, Float)] = []
        var overlap: [(Float, Float)] = []
        for ty in 0..<n_tiles_y {
            let cy = (CGFloat(ty) + 1) * half_tile
            for tx in 0..<n_tiles_x {
                let cx = (CGFloat(tx) + 1) * half_tile
                let i = (ty * n_tiles_x + tx) * 2
                let shift = (Float(texels[i]), Float(texels[i + 1]))
                if cx >= x0 + half_tile, cx <= x1 - half_tile, cy >= y0 + half_tile, cy <= y1 - half_tile {
                    inner.append(shift)
                } else if cx >= x0 - half_tile, cx <= x1 + half_tile, cy >= y0 - half_tile, cy <= y1 + half_tile {
                    overlap.append(shift)
                }
            }
        }
        let tiles = inner.count >= 4 ? inner : overlap
        guard tiles.count >= 4 else { return nil }
        
        // robust center: per-axis median shift, then mean per-tile deviation magnitude (the
        // median only makes the measure translation-invariant — no tiles are excluded)
        let med_x = Float(median_of_sorted(tiles.map { Double($0.0) }.sorted()))
        let med_y = Float(median_of_sorted(tiles.map { Double($0.1) }.sorted()))
        var sum = 0.0
        for shift in tiles {
            let dx = shift.0 - med_x, dy = shift.1 - med_y
            sum += Double(sqrt(dx * dx + dy * dy))
        }
        return Float(sum / Double(tiles.count))
    }
    
    /// The alignment texels of one frame (cached readback of the small tile-grid texture).
    func alignment_texels(for idx: Int) -> [Int16] {
        let frame = session.frames[idx]
        guard let alignment = frame.alignment_texture else { return [] }
        if let cached = texel_cache[idx] { return cached }
        let texels = read_alignment_texels(alignment)
        texel_cache[idx] = texels
        return texels
    }
    
    /// An all-zero alignment field with the burst's tile grid dimensions (the reference frame's
    /// alignment relative to itself). Used when visualizing the reference frame's alignment.
    func zero_alignment_texture() -> MTLTexture? {
        if let cached = zero_alignment { return cached }
        guard let tile_info = session.frames.compactMap({ $0.tile_info }).first else { return nil }
        let texture = make_alignment_like_texture(dx: 0, dy: 0, width: tile_info.n_tiles_x, height: tile_info.n_tiles_y, label: "Zero alignment (reference frame)")
        zero_alignment = texture
        return texture
    }
    
    /// An rg16Sint tile-grid texture filled with a constant (dx, dy) shift (level-0 pixels).
    /// Used to translate an unwarped frame by the anchor's shift.
    func constant_alignment_texture(dx: Int16, dy: Int16, width: Int, height: Int) -> MTLTexture {
        return make_alignment_like_texture(dx: dx, dy: dy, width: width, height: height, label: "Constant alignment (anchor shift)")
    }
    
    /// An rg16Sint tile-grid texture of the given size, filled with a constant (dx, dy) shift.
    private func make_alignment_like_texture(dx: Int16, dy: Int16, width: Int, height: Int, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Sint, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = label
        var data = [Int16](repeating: 0, count: width * height * 2)
        for i in 0..<(width * height) {
            data[2 * i] = dx
            data[2 * i + 1] = dy
        }
        data.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
    
    /// The (dx, dy) shift of one frame's tile at the given tile grid position (level-0 pixels).
    func alignment_offset(for idx: Int, tile_x: Int, tile_y: Int) -> [Float] {
        let frame = session.frames[idx]
        guard let alignment = frame.alignment_texture, !alignment_texels(for: idx).isEmpty else { return [0.0, 0.0] }
        let x = min(max(tile_x, 0), alignment.width - 1)
        let y = min(max(tile_y, 0), alignment.height - 1)
        let i = (y * alignment.width + x) * 2
        return [Float(alignment_texels(for: idx)[i]), Float(alignment_texels(for: idx)[i + 1])]
    }
    
    /// Robust brightness match estimated from a window of pooled pixels around the anchor point,
    /// so that the fit describes the neighborhood the user chose instead of the global image
    /// (whose moving content and occlusions would otherwise bias a global fit).
    func local_brightness_match(_ aligned: MTLTexture, anchor: AnchorPoint) -> (gain: Float, offset: Float, inlier_fraction: Float)? {
        guard !ref_pooled_values.isEmpty else { return nil }
        let (values, pool) = pooled_values(aligned, preferred_pool: 4)
        let width = aligned.width / pool
        let height = aligned.height / pool
        let center_x = min(max(Int((anchor.u * CGFloat(width)).rounded()), 0), width - 1)
        let center_y = min(max(Int((anchor.v * CGFloat(height)).rounded()), 0), height - 1)
        let radius = 48
        var ref_window: [Float] = []
        var comp_window: [Float] = []
        ref_window.reserveCapacity(4 * radius * radius)
        comp_window.reserveCapacity(4 * radius * radius)
        for y in max(0, center_y - radius)...min(height - 1, center_y + radius) {
            for x in max(0, center_x - radius)...min(width - 1, center_x + radius) {
                let i = y * width + x
                ref_window.append(ref_pooled_values[i])
                comp_window.append(values[i])
            }
        }
        // cap the number of samples for the (gain x offset) inlier search
        if ref_window.count > 4096 {
            let step = ref_window.count / 4096 + 1
            ref_window = (0..<ref_window.count).filter { $0 % step == 0 }.map { ref_window[$0] }
            comp_window = (0..<comp_window.count).filter { $0 % step == 0 }.map { comp_window[$0] }
        }
        var mean_ref = 0.0
        for value in ref_window { mean_ref += Double(value) }
        mean_ref /= Double(ref_window.count)
        let tolerance = Float(max(0.01, 0.04 * mean_ref))
        let fit = robust_brightness_match_values(ref_window, comp_window, tolerance: tolerance)
        return (fit.gain, fit.offset, fit.inlier_fraction)
    }
    
    /// Render one frame in the given mode. Called on a background thread.
    /// - `align_offset`: anchor offset (level-0 pixels) subtracted from all tile shifts.
    /// - `diff_white_override`: shared difference white point (already including the gain
    ///   multiplier); if nil, a per-frame white point (gain x this frame's mean difference) is used.
    func render(idx: Int, mode: InspectMode, alignment_scale: Int, align_offset: [Float], anchor: AnchorPoint?,
                diff_white_override: Float?, diff_gain: Float, match_exposure: Bool) -> InspectorRenderResult {
        switch mode {
        case .alignment, .flow:
            let frame = session.frames[idx]
            // the reference frame has no alignment field; its alignment relative to itself is zero
            let alignment = frame.alignment_texture ?? zero_alignment_texture()
            guard let alignment = alignment else { return InspectorRenderResult(bitmap: gray_bitmap_from_values([0], width: 1, height: 1, white_point: 1), info: "no alignment available") }
            let bitmap = render_alignment_bitmap(alignment, color_mode: mode == .alignment ? .rgb_axes : .hsv_flow,
                                                 scale: alignment_scale, block_size: 1, offset: align_offset)
            if frame.is_reference {
                let legend = mode == .alignment ? "uniform gray" : "uniform black"
                return InspectorRenderResult(bitmap: bitmap,
                    info: "reference frame · alignment is zero by definition (\(legend))")
            }
            let legend = mode == .alignment ? "zero shift = gray, red = +x, green = +y"
                                            : "hue = direction, brightness = magnitude"
            var info = String(format: "alignment colors saturate at %d level-0 px (%d sensor px), shared by all frames · %@",
                              alignment_scale, alignment_scale * frame.downscale_factor, legend)
            if align_offset != [0.0, 0.0] {
                info += " · RELATIVE to anchor"
            }
            return InspectorRenderResult(bitmap: bitmap, info: info)
            
        case .difference:
            let ref_texture = session.ref_texture_cropped
            let aligned = session.aligned_texture(for: idx)
            var gain: Float = 1.0
            var offset: Float = 0.0
            var fit_note = ""
            if match_exposure {
                if let a = anchor, calibrated, let local = local_brightness_match(aligned, anchor: a) {
                    // robust fit around the user-selected anchor: maximizes the number of pixels
                    // with approximately zero difference, ignoring moving content and occlusions
                    gain = local.gain
                    offset = local.offset
                    fit_note = String(format: "local robust fit around anchor, %.0f%% inliers", local.inlier_fraction * 100)
                } else {
                    let global = session.exposure_match(for: idx)
                    gain = global.gain
                    offset = global.offset
                    fit_note = (anchor != nil && !calibrated) ? "global fit (local needs calibration)" : "global fit"
                }
            }
            let abs_texture = abs_difference(ref_texture, aligned, gain: gain, offset: offset)
            let stats = texture_stats(abs_texture)
            let white: Float = diff_white_override ?? (diff_gain * stats.mean)
            let bitmap = render_signed_difference_bitmap(ref_texture, aligned, gain: gain, offset: offset,
                                                         white_point: max(white, 1e-6), pool: 4)
            var info = "red = warped brighter than reference, blue = warped darker, black = equal"
            if diff_white_override != nil {
                info += String(format: " · white point %.0f (shared)", white)
            } else {
                info += String(format: " · white point %.0f (per-frame)", white)
            }
            if match_exposure {
                info += String(format: " · ΔEV %+.3f (%@: gain %.3f, offset %+.1f) · mean |diff| %.1f",
                               -log2f(gain), fit_note, gain, offset, stats.mean)
            } else {
                info += " · raw (--raw-diff)"
            }
            return InspectorRenderResult(bitmap: bitmap, info: info)
            
        case .original:
            let frame = session.frames[idx]
            let texture: MTLTexture
            var info: String
            if frame.is_reference {
                texture = session.ref_texture_cropped
                info = "reference frame · unwarped by definition"
            } else if let a = anchor, let tile_info = frame.tile_info {
                // shift the unwarped frame by this frame's alignment at the anchor tile, so that
                // it stays registered with the reference around the anchor (like the alignment
                // views, which treat the anchor as zero)
                let offset = alignment_offset(for: idx, tile_x: a.tile_x, tile_y: a.tile_y)
                let constant = constant_alignment_texture(dx: Int16(offset[0]), dy: Int16(offset[1]),
                                                          width: tile_info.n_tiles_x, height: tile_info.n_tiles_y)
                let warped_texture = warp_texture(session.prepared_texture(for: idx, padded: true), constant, tile_info, frame.downscale_factor)
                texture = crop_texture(warped_texture, session.pad_x, session.pad_x, session.pad_y, session.pad_y)
                info = String(format: "original (unwarped) frame, shifted by (%.0f, %.0f) l0-px to match the anchor", offset[0], offset[1])
            } else {
                texture = session.prepared_texture(for: idx, padded: false)
                info = "original (unwarped) frame, exposure-equalized"
            }
            let stats = texture_stats(texture)
            let bitmap = render_gray_bitmap(texture, white_point: max(stats.max, 1e-6), gain: 1.0, pool: 4)
            info += String(format: " · white = brightest pooled pixel %.0f", stats.max)
            return InspectorRenderResult(bitmap: bitmap, info: info)
            
        case .warped:
            let texture = session.aligned_texture(for: idx)
            let stats = texture_stats(texture)
            let bitmap = render_gray_bitmap(texture, white_point: max(stats.max, 1e-6), gain: 1.0, pool: 4)
            let info = String(format: "warped candidate frame · white = brightest pooled pixel %.0f", stats.max)
            return InspectorRenderResult(bitmap: bitmap, info: info)
            
        case .reference:
            let texture = session.ref_texture_cropped
            let stats = texture_stats(texture)
            let bitmap = render_gray_bitmap(texture, white_point: max(stats.max, 1e-6), gain: 1.0, pool: 4)
            let info = String(format: "reference frame · white = brightest pooled pixel %.0f", stats.max)
            return InspectorRenderResult(bitmap: bitmap, info: info)
        }
    }
}


/// Median of an already sorted array.
private func median_of_sorted(_ values: [Double]) -> Double {
    if values.isEmpty { return 1.0 }
    let mid = values.count / 2
    return values.count % 2 == 1 ? values[mid] : 0.5 * (values[mid - 1] + values[mid])
}


struct AlignmentInspectorView: View {
    @ObservedObject var coordinator: InspectionCoordinator
    
    var body: some View {
        Group {
            if let session = coordinator.session {
                InspectorContentView(session: session, coordinator: coordinator)
                    .id(ObjectIdentifier(session))  // reset all local state when a new burst is inspected
            } else {
                Text("No burst loaded.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 940, minHeight: 580)
    }
}


/// One queued main-view render: a frame index plus the parameters it should be rendered with.
/// Parameter-independent fields only — the per-frame anchor offset is computed at render time.
private struct RenderParams: Equatable {
    var mode: InspectMode
    var alignment_scale: Int
    var anchor: AnchorPoint?
    var diff_white: Float?
    var diff_gain: Float
    var match_exposure: Bool
}

private struct RenderRequest: Equatable {
    var idx: Int
    var params: RenderParams
}


private struct InspectorContentView: View {
    let session: InspectionSession
    @ObservedObject var coordinator: InspectionCoordinator
    @StateObject private var model: InspectorModel
    
    @State private var selected_idx: Int
    @State private var selection: Set<Int>
    @State private var last_clicked: Int
    @State private var excluded: Set<Int> = []
    @State private var mode: InspectMode = .alignment
    @State private var align_shared = true
    @State private var align_manual_scale: Double = 32
    @State private var diff_shared = true
    @State private var diff_gain: Double = 4.0
    @State private var match_exposure = true
    @State private var anchor: AnchorPoint?
    /// false while the anchor follows the subject area automatically; set to true as soon as the
    /// user places (or clears) the anchor manually, after which ROI changes no longer move it
    @State private var anchor_manual = false
    @State private var roi: RoiRect?
    @State private var sort_mode = 0  // 0 = frame order, 1 = difference score, 2 = alignment variation
    @State private var rendered: NSImage?
    @State private var rendered_info: String = ""
    @State private var rendering = false
    @State private var render_queue: [RenderRequest] = []
    @State private var render_busy = false
    @State private var last_queued_params: RenderParams?
    @State private var last_thumb_params = ""
    @State private var zoom: CGFloat = 1
    @State private var key_monitor: Any?
    @State private var list_proxy: ScrollViewProxy?
    
    init(session: InspectionSession, coordinator: InspectionCoordinator) {
        self.session = session
        self.coordinator = coordinator
        _model = StateObject(wrappedValue: InspectorModel(session: session))
        let initial = min(session.ref_idx + 1, session.frames.count - 1)
        _selected_idx = State(initialValue: initial)
        _selection = State(initialValue: [initial])
        _last_clicked = State(initialValue: initial)
        let default_roi = InspectorContentView.subject_default_roi(session: session)
        _roi = State(initialValue: default_roi)
        // anchor starts at the subject-area midpoint (still automatic; a manual click or
        // "Clear anchor" hands control to the user)
        var initial_anchor: AnchorPoint? = nil
        if let roi_in = default_roi, let tile_info = session.frames.compactMap({ $0.tile_info }).first {
            let u = (roi_in.x0 + roi_in.x1) / 2, v = (roi_in.y0 + roi_in.y1) / 2
            let downscale = Double(session.frames[initial].downscale_factor)
            let half_tile = Double(tile_info.tile_size) / 2
            let gx = ((u * Double(session.ref_texture_cropped.width) + Double(session.pad_x)) / downscale + 0.5) / half_tile - 1
            let gy = ((v * Double(session.ref_texture_cropped.height) + Double(session.pad_y)) / downscale + 0.5) / half_tile - 1
            initial_anchor = AnchorPoint(u: u, v: v,
                                         tile_x: min(max(Int(gx.rounded()), 0), tile_info.n_tiles_x - 1),
                                         tile_y: min(max(Int(gy.rounded()), 0), tile_info.n_tiles_y - 1))
        }
        _anchor = State(initialValue: initial_anchor)
    }
    
    /// Default subject area: the reference frame's autofocus point (from the Nikon AFInfo2 maker
    /// notes), doubled around its center to form a usable scoring region. Nil if the camera
    /// recorded no AF position.
    private static func subject_default_roi(session: InspectionSession) -> RoiRect? {
        guard let af = session.af_area, af.image_width > 0, af.image_height > 0 else { return nil }
        let image_w = CGFloat(af.image_width), image_h = CGFloat(af.image_height)
        let cx = CGFloat(af.x) / image_w
        let cy = CGFloat(af.y) / image_h
        let extent_w = max(CGFloat(af.width) / image_w * 2.0, 0.04)  // 2x the AF area, min 4% of frame
        let extent_h = max(CGFloat(af.height) / image_h * 2.0, 0.04)
        return RoiRect(x0: max(0, cx - extent_w / 2), y0: max(0, cy - extent_h / 2),
                       x1: min(1, cx + extent_w / 2), y1: min(1, cy + extent_h / 2))
    }
    
    var selected_frame: InspectionFrame { session.frames[selected_idx] }
    
    /// tile geometry of the (shared) tile grid, available for every frame via the comparison frames
    var reference_tile_info: TileInfo? { session.frames.compactMap { $0.tile_info }.first }
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                frame_list.frame(width: 225)
                Divider()
                image_area
            }
            Divider()
            stats_bar
            Divider()
            merge_bar
        }
        .onAppear {
            model.start_background_work()
            install_key_monitor()
            schedule_render()
        }
        .onDisappear {
            if let monitor = key_monitor {
                NSEvent.removeMonitor(monitor)
                key_monitor = nil
            }
        }
        .onChange(of: selected_idx) { _ in
            schedule_render()
        }
        .onChange(of: mode) { _ in schedule_render() }
        .onChange(of: model.calibration_progress) { _ in model.compute_roi_scores(roi: roi); schedule_render() }
        .onChange(of: align_shared) { _ in schedule_render() }
        .onChange(of: align_manual_scale) { _ in schedule_render() }
        .onChange(of: diff_shared) { _ in schedule_render() }
        .onChange(of: diff_gain) { _ in schedule_render() }
        .onChange(of: match_exposure) { _ in schedule_render() }
        .onChange(of: model.calibrated) { _ in model.compute_roi_scores(roi: roi); schedule_render() }
        .onChange(of: roi) { _ in
            model.compute_roi_scores(roi: roi)
            // while the user has not taken manual control of the anchor, it follows the subject area
            if !anchor_manual {
                anchor = roi.flatMap { scene_anchor(u: ($0.x0 + $0.x1) / 2, v: ($0.y0 + $0.y1) / 2) }
                schedule_render()
            }
        }
    }
    
    // MARK: toolbar
    
    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(InspectMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 510)
            
            if mode.is_alignment {
                Toggle("Shared scale", isOn: $align_shared)
                if !align_shared {
                    Text("±\(Int(align_manual_scale)) px")
                        .font(.system(size: 11)).opacity(0.8).frame(width: 52)
                    Slider(value: $align_manual_scale, in: 4...252, step: 2).frame(width: 110)
                }
            } else if mode == .difference {
                Toggle("Match brightness", isOn: $match_exposure)
                Toggle("Shared scale", isOn: $diff_shared).disabled(!match_exposure)
                Text(String(format: "gain %.1f", diff_gain))
                    .font(.system(size: 11)).opacity(0.8).frame(width: 58)
                Slider(value: $diff_gain, in: 0.5...20, step: 0.5).frame(width: 110)
            }
            Spacer()
            if anchor != nil {
                Button(action: {
                    anchor = nil
                    anchor_manual = true  // manual removal: ROI changes no longer re-place the anchor
                    schedule_render()
                }, label: {
                    Text("Clear anchor").font(.system(size: 11))
                })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: frame list
    
    private var frame_list: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Picker("Sort", selection: $sort_mode) {
                    Text("frame").tag(0)
                    Text("diff").tag(1)
                    Text("align").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 150)
                .controlSize(.small)
                Spacer()
                if roi != nil {
                    Button(action: { roi = nil }) {
                        Text("Clear subject").font(.system(size: 10))
                    }
                } else {
                    Text("drag on image to mark subject")
                        .font(.system(size: 9)).opacity(0.45)
                }
            }
            .padding(.horizontal, 8)
            HStack(spacing: 6) {
                Spacer()
                Text("diff")
                    .font(.system(size: 9)).opacity(0.45)
                    .frame(width: 42, alignment: .trailing)
                    .help("Mean difference to the reference inside the subject area (lower = more similar)")
                Text("align")
                    .font(.system(size: 9)).opacity(0.45)
                    .frame(width: 42, alignment: .trailing)
                    .help("Variation of the alignment field inside the subject area (lower = cleaner mapping)")
            }
            .padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(display_indices, id: \.self) { idx in
                            let frame = session.frames[idx]
                            FrameRow(frame: frame,
                                     is_selected: selection.contains(idx),
                                     included: !excluded.contains(idx),
                                     thumbnail: model.thumbnails[idx],
                                     score: model.roi_scores[idx],
                                     align_score: model.roi_align_scores[idx],
                                     on_toggle_included: { toggle_included(idx) },
                                     on_click: { row_clicked(idx) })
                                .id(idx)
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    list_proxy = proxy
                    proxy.scrollTo(selected_idx, anchor: .center)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    /// Frame indices in current display order: capture order, or (diff / align) sorted by the
    /// chosen subject-area score, ascending (best first). Frames without a score yet and the
    /// reference keep capture order after the scored ones; the reference row is pinned to the top
    /// in score modes so it stays easy to find.
    private var display_indices: [Int] {
        let scores = sort_mode == 2 ? model.roi_align_scores : model.roi_scores
        guard sort_mode > 0, !scores.isEmpty else {
            return session.frames.map { $0.index }
        }
        let ranked = session.frames.sorted { a, b in
            // rank: scored comparison frames first (ascending), reference/unscored after, in
            // capture order; the reference moves to the very front
            func rank(_ frame: InspectionFrame) -> Int {
                if frame.is_reference { return 0 }
                return scores[frame.index] != nil ? 1 : 2
            }
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            if ra == 1 {
                let (sa, sb) = (scores[a.index]!, scores[b.index]!)
                if sa != sb { return sa < sb }
            }
            return a.index < b.index
        }
        return ranked.map { $0.index }
    }
    
    /// Plain click selects one row; cmd-click adds/removes it from the selection; shift-click
    /// adds/removes the range from the last clicked row to this one.
    private func row_clicked(_ idx: Int) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(idx) {
                selection.remove(idx)
            } else {
                selection.insert(idx)
            }
        } else if modifiers.contains(.shift) {
            let lower = min(last_clicked, idx)
            let upper = max(last_clicked, idx)
            let range = Set(lower...upper)
            if selection.contains(idx) {
                selection.subtract(range)
            } else {
                selection.formUnion(range)
            }
        } else {
            selection = [idx]
        }
        selected_idx = idx
        last_clicked = idx
    }
    
    /// Check/uncheck a row. If the row belongs to a multi-selection, all selected rows follow.
    private func toggle_included(_ idx: Int) {
        let make_excluded = !excluded.contains(idx)
        if selection.contains(idx) && selection.count > 1 {
            if make_excluded {
                excluded.formUnion(selection)
            } else {
                excluded.subtract(selection)
            }
        } else if make_excluded {
            excluded.insert(idx)
        } else {
            excluded.remove(idx)
        }
    }
    
    // MARK: image area
    
    // MARK: image area
    
    private var image_area: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = rendered {
                ZoomableScrollImage(image: image,
                                    pixelated: mode.is_alignment,
                                    marker: mode.is_alignment ? anchor : nil,
                                    roi: roi,
                                    on_anchor_click: { u, v in set_anchor(u: u, v: v) },
                                    on_roi_set: { roi = $0 },
                                    on_double_click: { zoom = 1 },
                                    on_zoom: { zoom = min(max($0, 1), 16) })
            } else {
                Color.black
                ProgressView().opacity(0.5)
            }
            if rendering {
                ProgressView().scaleEffect(0.6)
            }
            if rendered != nil {
                Text(String(format: "×%.1f  (double-click to reset)", zoom))
                    .font(.system(size: 10))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                    .foregroundColor(.white)
                    .padding(8)
            }
        }
        .background(Color.black)
    }
    
    /// Set the anchor point from a click on the image. The fractional position identifies the
    /// scene point (identical in all frames, since every frame is warped to the reference); the
    /// tile grid cell under it provides the per-frame shift that is subtracted from the field.
    private func set_anchor(u: CGFloat, v: CGFloat) {
        let u = min(max(u, 0), 1)
        let v = min(max(v, 0), 1)
        
        guard let tile_info = reference_tile_info else { return }
        let n_tiles_x = tile_info.n_tiles_x
        let n_tiles_y = tile_info.n_tiles_y
        
        var tile_x: Int
        var tile_y: Int
        if mode.is_alignment {
            // click on the tile-grid visualization: one bitmap pixel = one tile
            tile_x = min(max(Int((u * CGFloat(n_tiles_x) - 0.5).rounded()), 0), n_tiles_x - 1)
            tile_y = min(max(Int((v * CGFloat(n_tiles_y) - 0.5).rounded()), 0), n_tiles_y - 1)
        } else if let scene = scene_anchor(u: u, v: v) {
            tile_x = scene.tile_x
            tile_y = scene.tile_y
        } else {
            return
        }
        anchor = AnchorPoint(u: u, v: v, tile_x: tile_x, tile_y: tile_y)
        anchor_manual = true
        schedule_render()
    }
    
    /// Anchor at a fractional scene position, mapped through the level-0 tile grid (the grid
    /// covers the PADDED frame at 1/downscale scale; tile ix centers at level-0 x =
    /// (ix + 1) * tile_size / 2, see warp_texture_bayer). Used for manual clicks in photo modes
    /// and for auto-placing the anchor at the subject-area midpoint.
    private func scene_anchor(u: CGFloat, v: CGFloat) -> AnchorPoint? {
        guard let tile_info = reference_tile_info else { return nil }
        let downscale = Double(selected_frame.downscale_factor)
        let half_tile = Double(tile_info.tile_size) / 2
        let gx = ((u * Double(session.ref_texture_cropped.width) + Double(session.pad_x)) / downscale + 0.5) / half_tile - 1
        let gy = ((v * Double(session.ref_texture_cropped.height) + Double(session.pad_y)) / downscale + 0.5) / half_tile - 1
        return AnchorPoint(u: u, v: v,
                           tile_x: min(max(Int(gx.rounded()), 0), tile_info.n_tiles_x - 1),
                           tile_y: min(max(Int(gy.rounded()), 0), tile_info.n_tiles_y - 1))
    }
    
    // MARK: stats + info bar
    
    private var anchor_text: String? {
        guard let a = anchor, reference_tile_info != nil else { return nil }
        let offset = model.alignment_offset(for: selected_idx, tile_x: a.tile_x, tile_y: a.tile_y)
        let factor = Float(selected_frame.downscale_factor)
        return String(format: "anchor tile (%d, %d): shift (%.0f, %.0f) l0-px = (%.0f, %.0f) sensor px",
                      a.tile_x, a.tile_y, offset[0], offset[1], offset[0] * factor, offset[1] * factor)
    }
    
    private var stats_text: String {
        let frame = selected_frame
        if frame.is_reference {
            return "frame \(frame.index) — \(frame.url.lastPathComponent) — reference frame"
        }
        var parts = ["frame \(frame.index) — \(frame.url.lastPathComponent)"]
        if let stats = frame.stats {
            parts.append(String(format: "mean |shift| %.1f l0-px (%.1f sensor px)", stats.mean_magnitude,
                                stats.mean_magnitude * Double(frame.downscale_factor)))
            parts.append(String(format: "max %d l0-px", stats.max_abs_shift))
        }
        return parts.joined(separator: " · ")
    }
    
    private var calibration_hint: String? {
        guard mode == .difference && diff_shared && match_exposure && !model.calibrated else { return nil }
        let total = session.frames.filter { !$0.is_reference }.count
        return "measuring shared scale… \(model.calibration_progress)/\(total)"
    }
    
    private var stats_bar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(stats_text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let hint = calibration_hint {
                    Text(hint).font(.system(size: 11)).opacity(0.7)
                }
            }
            HStack {
                Text([rendered_info, anchor_text].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .opacity(0.7)
                    .lineLimit(1)
                Spacer()
                Text("↑/↓ frame · ←/→ mode · space = check · click = anchor · pinch zoom, double-click reset")
                    .font(.system(size: 10)).opacity(0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: merge bar
    
    private var merge_bar: some View {
        let included_count = session.frames.count - excluded.count
        return HStack {
            if included_count == session.frames.count {
                Text("Merging discards the inspection view and runs the full alignment + merge pipeline.")
                    .font(.system(size: 11))
                    .opacity(0.6)
            } else {
                Text("Merging \(included_count) of \(session.frames.count) images; unchecked images are excluded (the merge picks its own reference from the included images).")
                    .font(.system(size: 11))
                    .opacity(0.6)
            }
            Spacer()
            Button(action: {
                guard let handler = coordinator.merge_handler, let session = coordinator.session else { return }
                let urls = session.frames.filter { !excluded.contains($0.index) }.map { $0.url }
                coordinator.dismiss()
                // let the inspection view (and its burst textures) be released before the merge reloads everything
                DispatchQueue.main.async { handler(urls) }
            }, label: {
                Text("Merge into image")
            })
            .disabled(included_count < 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: keyboard navigation
    
    private func install_key_monitor() {
        guard key_monitor == nil else { return }
        key_monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            return self.handle_key_event(event)
        }
    }
    
    private func handle_key_event(_ event: NSEvent) -> NSEvent? {
        guard let window = coordinator.window, event.window === window else { return event }
        // don't hijack keys while text input has focus
        if let responder = window.firstResponder, responder is NSTextView || responder is NSText {
            return event
        }
        if event.type == .keyDown && event.keyCode == 53 && roi != nil {
            roi = nil  // escape: clear the subject area (onChange recomputes the scores)
            return nil
        }
        guard event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 49 else { return event }
        if event.type == .keyUp {
            // released the up/down arrow: stop scrubbing right where the selection ended
            if event.keyCode == 125 || event.keyCode == 126 {
                cancel_scrub()
            }
            return nil
        }
        if event.keyCode == 49 {
            // space: check/uncheck the current image (guard against key auto-repeat)
            if !event.isARepeat {
                toggle_included(selected_idx)
            }
            return nil
        }
        switch event.keyCode {
        case 125: move_selection(+1)   // down arrow
        case 126: move_selection(-1)   // up arrow
        case 123: move_mode(-1)        // left arrow: previous tab
        case 124: move_mode(+1)        // right arrow: next tab
        default: break
        }
        return nil
    }
    
    private func move_mode(_ delta: Int) {
        let all = InspectMode.allCases
        guard let current = all.firstIndex(of: mode) else { return }
        let next = min(max(current + delta, 0), all.count - 1)
        if all[next] != mode {
            mode = all[next]
        }
    }
    
    /// Called when the arrow key is released: drop all queued scrub frames (the in-flight render
    /// still finishes) and queue a single render of the frame the selection ended at, so the view
    /// converges on it.
    private func cancel_scrub() {
        render_queue.removeAll()
        if render_busy, let params = last_queued_params {
            render_queue = [RenderRequest(idx: selected_idx, params: params)]
        }
        pump_renders()
    }
    
    private func move_selection(_ delta: Int) {
        // follow the VISIBLE order (capture order, or score-sorted) rather than frame indices
        let order = display_indices
        guard let position = order.firstIndex(of: selected_idx) else { return }
        let next = order[min(max(position + delta, 0), order.count - 1)]
        if next != selected_idx {
            selected_idx = next
            selection = [next]
            last_clicked = next
            list_proxy?.scrollTo(next, anchor: .center)
        }
    }
    
    // MARK: rendering
    
    private func schedule_render() {
        update_thumbnails()
        
        let params = RenderParams(
            mode: mode,
            alignment_scale: align_shared ? model.alignment_scale : max(Int(align_manual_scale), 1),
            anchor: anchor,
            diff_white: (mode == .difference && diff_shared && match_exposure && model.calibrated) ? Float(diff_gain) * model.median_diff_mean : nil,
            diff_gain: Float(diff_gain),
            match_exposure: match_exposure)
        let request = RenderRequest(idx: selected_idx, params: params)
        
        // a parameter change (mode, gain, anchor, ...) invalidates everything queued so far, so that
        // control changes respond instantly even while a long scrub backlog is draining; repeated
        // identical requests (e.g. key repeats on the same frame) are coalesced
        if params != last_queued_params {
            render_queue.removeAll()
            last_queued_params = params
        }
        if render_queue.last != request {
            render_queue.append(request)
            if render_queue.count > 64 {
                render_queue.removeFirst()
            }
        }
        pump_renders()
    }
    
    /// Render queued requests one at a time, IN ORDER, and publish every result. Holding the
    /// arrow keys therefore shows every intermediate frame while scrubbing (at the render speed
    /// of the selected mode), instead of skipping straight to the final frame.
    private func pump_renders() {
        guard !render_busy, let request = render_queue.first else { return }
        render_busy = true
        rendering = true
        render_queue.removeFirst()
        let model = self.model
        DispatchQueue.global().async {
            autoreleasepool {
                let align_offset: [Float]
                if request.params.mode.is_alignment, let a = request.params.anchor {
                    align_offset = model.alignment_offset(for: request.idx, tile_x: a.tile_x, tile_y: a.tile_y)
                } else {
                    align_offset = [0.0, 0.0]
                }
                let result = model.render(idx: request.idx, mode: request.params.mode,
                                          alignment_scale: request.params.alignment_scale,
                                          align_offset: align_offset, anchor: request.params.anchor,
                                          diff_white_override: request.params.diff_white,
                                          diff_gain: request.params.diff_gain,
                                          match_exposure: request.params.match_exposure)
                let image = NSImage(size: NSSize(width: result.bitmap.pixelsWide, height: result.bitmap.pixelsHigh))
                image.addRepresentation(result.bitmap)
                DispatchQueue.main.async {
                    self.rendered = image
                    self.rendered_info = result.info
                    self.render_busy = false
                    self.rendering = !self.render_queue.isEmpty
                    self.pump_renders()
                }
            }
        }
    }
    
    /// Regenerate the frame-list thumbnails if the parameters they depend on changed.
    private func update_thumbnails() {
        // reference/original modes keep the previous mode's thumbnails (the reference row always
        // shows the reference preview)
        guard mode != .reference && mode != .original else { return }
        let alignment_scale = align_shared ? model.alignment_scale : max(Int(align_manual_scale), 1)
        // calibration progress is part of the parameters so that difference/warped thumbnails are
        // regenerated periodically while the calibration pass fills in the per-frame data
        let params = "\(mode.rawValue)|\(alignment_scale)|\(anchor.map { "\($0.tile_x),\($0.tile_y)" } ?? "none")|\(mode == .difference ? diff_gain : 0)|\(model.calibrated)|\(model.calibration_progress / 10)"
        guard params != last_thumb_params else { return }
        last_thumb_params = params
        model.regenerate_thumbnails(mode: mode, align_scale: alignment_scale,
                                    anchor_tile: anchor.map { (x: $0.tile_x, y: $0.tile_y) },
                                    diff_gain: Float(diff_gain))
    }
}


/// Circular marker showing the anchor point inside the alignment visualization.
private struct AnchorMarker: View {
    let u: CGFloat
    let v: CGFloat
    let origin: CGPoint
    let size: CGSize
    
    var body: some View {
        Circle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .shadow(color: Color.black.opacity(0.6), radius: 1)
            .frame(width: 13, height: 13)
            .position(x: origin.x + u * size.width, y: origin.y + v * size.height)
            .allowsHitTesting(false)
    }
}


/// NSScrollView-based zoomable/pannable image view. Pinch to zoom is CENTERED ON THE CURSOR
/// (native NSScrollView magnification), the scroll wheel pans, double-click resets the zoom, and
/// a single click reports the fractional image position (used for the alignment anchor).
private struct ZoomableScrollImage: NSViewRepresentable {
    let image: NSImage
    let pixelated: Bool
    let marker: AnchorPoint?
    let roi: RoiRect?
    let on_anchor_click: (CGFloat, CGFloat) -> Void
    let on_roi_set: (RoiRect) -> Void
    let on_double_click: () -> Void
    let on_zoom: (CGFloat) -> Void
    
    final class Coordinator {
        weak var image_view: PixelImageView?
        weak var scroll_view: ZoomReportScrollView?
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scroll_view = ZoomReportScrollView()
        scroll_view.hasVerticalScroller = true
        scroll_view.hasHorizontalScroller = true
        scroll_view.autohidesScrollers = true
        scroll_view.allowsMagnification = true
        scroll_view.minMagnification = 1
        scroll_view.maxMagnification = 16
        scroll_view.drawsBackground = true
        scroll_view.backgroundColor = .black
        scroll_view.borderType = .noBorder
        let image_view = PixelImageView()
        image_view.frame = scroll_view.contentView.bounds
        image_view.autoresizingMask = [.width, .height]
        scroll_view.documentView = image_view
        context.coordinator.image_view = image_view
        context.coordinator.scroll_view = scroll_view
        return scroll_view
    }
    
    func updateNSView(_ ns_view: NSScrollView, context: Context) {
        guard let image_view = context.coordinator.image_view,
              let scroll_view = context.coordinator.scroll_view else { return }
        image_view.set_content(image: image, pixelated: pixelated, marker: marker)
        image_view.set_roi(roi)
        image_view.on_anchor_click = on_anchor_click
        image_view.on_roi_set = on_roi_set
        image_view.on_double_click = on_double_click
        scroll_view.on_zoom = on_zoom
    }
}


/// Scroll view that reports its magnification (e.g. during pinch gestures).
private final class ZoomReportScrollView: NSScrollView {
    var on_zoom: ((CGFloat) -> Void)?
    
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        on_zoom?(magnification)
    }
}


/// Monochrome-friendly image view: draws the image fitted into the view (letterboxed, black
/// background), with nearest-neighbor interpolation for tile-grid visualizations, and an anchor
/// marker as a subview.
private final class PixelImageView: NSView {
    var on_anchor_click: ((CGFloat, CGFloat) -> Void)?
    var on_roi_set: ((RoiRect) -> Void)?
    var on_double_click: (() -> Void)?
    private var source: NSImage?
    private var pixelated = false
    private var marker: AnchorPoint?
    private var roi_fraction: RoiRect?
    private var live_fraction: RoiRect?
    private var drag_start_location: CGPoint?
    private var drag_is_roi = false
    private var drag_click_count = 0
    private let marker_view = AnchorMarkerView()
    private let roi_view = SelectionOverlayView()
    
    override var isFlipped: Bool { true }  // fractional y measured from the top, like the visualizations
    
    init() {
        super.init(frame: NSRect.zero)
        wantsLayer = true
        addSubview(roi_view)
        addSubview(marker_view)
        marker_view.isHidden = true
    }
    
    required init?(coder: NSCoder) { fatalError("not supported") }
    
    func set_content(image: NSImage, pixelated: Bool, marker: AnchorPoint?) {
        if source !== image {
            source = image
            needsDisplay = true
        }
        if self.pixelated != pixelated {
            self.pixelated = pixelated
            needsDisplay = true
        }
        self.marker = marker
        position_marker()
    }
    
    func set_roi(_ roi: RoiRect?) {
        if roi != roi_fraction {
            roi_fraction = roi
            position_roi()
        }
    }
    
    /// rect of the fitted (letterboxed) image inside the view bounds
    private var fitted_rect: CGRect {
        guard let image = source, bounds.width > 0, bounds.height > 0 else { return CGRect.zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    
    override func draw(_ dirty_rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = source else { return }
        NSGraphicsContext.current?.imageInterpolation = pixelated ? .none : .high
        // respectFlipped: true — the view is flipped (top-left origin); without compensation the
        // image would be drawn vertically mirrored
        image.draw(in: fitted_rect, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
    }
    
    override func layout() {
        super.layout()
        position_marker()
        position_roi()
    }
    
    private func position_marker() {
        if let marker = marker, !fitted_rect.isEmpty {
            let size: CGFloat = 13
            marker_view.frame = CGRect(x: fitted_rect.origin.x + marker.u * fitted_rect.width - size / 2,
                                       y: fitted_rect.origin.y + marker.v * fitted_rect.height - size / 2,
                                       width: size, height: size)
            marker_view.isHidden = false
        } else {
            marker_view.isHidden = true
        }
    }
    
    /// commit the subject-area rectangle (fractions) onto the overlay subview
    private func position_roi() {
        roi_view.frame = bounds  // the overlay had no frame -> nothing was ever drawn
        let rect = fitted_rect
        func view_rect(_ f: RoiRect) -> CGRect {
            let x0 = rect.minX + f.x0 * rect.width
            let y0 = rect.minY + f.y0 * rect.height
            let x1 = rect.minX + f.x1 * rect.width
            let y1 = rect.minY + f.y1 * rect.height
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        if rect.isEmpty {
            roi_view.committed_rect = nil
            roi_view.live_rect = nil
        } else {
            roi_view.committed_rect = live_fraction == nil ? roi_fraction.map(view_rect) : nil
            roi_view.live_rect = live_fraction.map(view_rect)
        }
        roi_view.isHidden = roi_view.committed_rect == nil && roi_view.live_rect == nil
        roi_view.needsDisplay = true
    }
    
    // MARK: mouse handling — plain click sets the anchor, double-click resets zoom, drag marks
    // the subject area rectangle
    
    override func mouseDown(with event: NSEvent) {
        let rect = fitted_rect
        let location = convert(event.locationInWindow, from: nil)
        guard !rect.isEmpty, rect.contains(location) else { return }
        drag_start_location = location
        drag_is_roi = false
        drag_click_count = event.clickCount
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let start = drag_start_location else { return }
        let location = convert(event.locationInWindow, from: nil)
        if !drag_is_roi {
            guard hypot(location.x - start.x, location.y - start.y) > 4 else { return }
            drag_is_roi = true
        }
        let rect = fitted_rect
        let x0 = min(max(start.x, rect.minX), rect.maxX)
        let y0 = min(max(start.y, rect.minY), rect.maxY)
        let x1 = min(max(location.x, rect.minX), rect.maxX)
        let y1 = min(max(location.y, rect.minY), rect.maxY)
        live_fraction = RoiRect(x0: (x0 - rect.minX) / rect.width,
                                y0: (y0 - rect.minY) / rect.height,
                                x1: (x1 - rect.minX) / rect.width,
                                y1: (y1 - rect.minY) / rect.height).normalized()
        position_roi()
    }
    
    override func mouseUp(with event: NSEvent) {
        guard drag_start_location != nil else { return }
        let was_drag = drag_is_roi
        let click_count = drag_click_count
        let dragged_fraction = live_fraction
        drag_start_location = nil
        drag_is_roi = false
        live_fraction = nil
        position_roi()
        if was_drag {
            // finished a subject-area drag; ignore degenerate rects (>4 px but still tiny)
            if let f = dragged_fraction, !f.is_degenerate {
                on_roi_set?(f)
            }
            return
        }
        let rect = fitted_rect
        let location = convert(event.locationInWindow, from: nil)
        guard !rect.isEmpty, rect.contains(location) else { return }
        if click_count >= 2 {
            on_double_click?()
        } else {
            on_anchor_click?((location.x - rect.minX) / rect.width, (location.y - rect.minY) / rect.height)
        }
    }
}


/// Circular anchor marker (drawn in image-fraction coordinates, scales with the zoom).
private final class AnchorMarkerView: NSView {
    override func draw(_ dirty_rect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// Draws the committed subject-area rectangle (dashed) and the in-progress drag rectangle
/// (solid, slightly brighter) on top of the image.
private final class SelectionOverlayView: NSView {
    var committed_rect: CGRect?
    var live_rect: CGRect?
    
    override var isFlipped: Bool { true }  // match the parent view: y measured from the top
    
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // mouse events pass through
    
    override func draw(_ dirty_rect: NSRect) {
        guard let rect = live_rect ?? committed_rect, rect.width > 1, rect.height > 1 else { return }
        let is_live = live_rect != nil
        // darken everything OUTSIDE the subject area
        NSColor.black.withAlphaComponent(0.55).setFill()
        let strips = [
            CGRect(x: 0, y: 0, width: bounds.width, height: max(rect.minY, 0)),                              // top
            CGRect(x: 0, y: rect.maxY, width: bounds.width, height: max(bounds.maxY - rect.maxY, 0)),        // bottom
            CGRect(x: 0, y: rect.minY, width: max(rect.minX, 0), height: rect.height),                       // left
            CGRect(x: rect.maxX, y: rect.minY, width: max(bounds.maxX - rect.maxX, 0), height: rect.height), // right
        ]
        for strip in strips where strip.width > 0.5 && strip.height > 0.5 {
            strip.fill()
        }
        // thin light border around the area itself
        let path = NSBezierPath(rect: rect)
        path.lineWidth = is_live ? 1.5 : 1.0
        NSColor.white.withAlphaComponent(is_live ? 0.9 : 0.6).setStroke()
        path.stroke()
    }
}
/// One row of the frame list: include checkbox, alignment thumbnail, frame number, file name.
private struct FrameRow: View {
    let frame: InspectionFrame
    let is_selected: Bool
    let included: Bool
    let thumbnail: NSImage?
    let score: Float?
    let align_score: Float?
    let on_toggle_included: () -> Void
    let on_click: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Button(action: on_toggle_included) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(included ? Color.accentColor : Color.clear)
                        .frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if included {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(included ? "Included in the merge (click to exclude)" : "Excluded from the merge (click to include)")
            
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(NSColor.textBackgroundColor))
                        .frame(width: 44, height: 30)
                    if let image = thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 30)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(String(format: "frame %02d", frame.index))
                            .font(.system(size: 11, weight: .medium))
                        if frame.is_reference {
                            Text("REF")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 2).fill(Color.accentColor))
                                .foregroundColor(.white)
                        }
                    }
                    Text(frame.url.lastPathComponent)
                        .font(.system(size: 9))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer()
                Text(score.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(score == nil ? 0.3 : 0.85)
                    .frame(width: 42, alignment: .trailing)
                    .help(score == nil ? "No subject-area score (drag a rectangle on the image)"
                          : "Mean difference to the reference inside the subject area (lower = more similar)")
                Text(align_score.map { String(format: "%.2f", $0) } ?? "–")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .opacity(align_score == nil ? 0.3 : 0.85)
                    .frame(width: 42, alignment: .trailing)
                    .help(align_score == nil ? "No alignment-variation score (drag a rectangle on the image)"
                          : "Variation of the alignment field inside the subject area, in level-0 pixels (lower = cleaner mapping)")
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { _ in on_click() })
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(is_selected ? Color.accentColor.opacity(0.22) : Color.clear))
    }
}
