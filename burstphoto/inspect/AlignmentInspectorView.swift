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
   own frame, so the anchor becomes zero and the field shows the deformation RELATIVE to it.
 - Up/down arrow keys select the previous/next frame.
 */
import SwiftUI
import AppKit
import Combine


/// Visualization modes of the inspector window.
enum InspectMode: String, CaseIterable, Identifiable {
    case alignment  = "Alignment"   // per-tile shift, R = +x, G = +y, zero = 50% gray
    case flow       = "Flow"        // per-tile shift, hue = direction, brightness = magnitude
    case difference = "Difference"  // |reference - warped candidate|, brightness-matched
    case warped     = "Warped"      // warped candidate frame
    case reference  = "Reference"   // reference frame
    
    var id: String { rawValue }
    var is_alignment: Bool { self == .alignment || self == .flow }
}


/// A user-selected anchor point: fractional position in the frame plus the tile grid cell under it.
struct AnchorPoint {
    var u: CGFloat
    var v: CGFloat
    var tile_x: Int
    var tile_y: Int
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
    }
    private(set) var frame_data: [Int: FrameThumbnailData] = [:]
    private var ref_data: Downsampled?
    
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
                let data = FrameThumbnailData(
                    warped: Downsampled(values: warped_ds.values, width: warped_ds.width, height: warped_ds.height),
                    warped_max: warped_max,
                    diff: Downsampled(values: diff_ds.values, width: diff_ds.width, height: diff_ds.height),
                    diff_mean: Float(diff_sum / Double(values.count)))
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
                    guard let data = model.frame_data[frame.index] else { continue }
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
                    guard let data = model.frame_data[frame.index] else { continue }
                    let bitmap = gray_bitmap_from_values(data.warped.values, width: data.warped.width, height: data.warped.height,
                                                         white_point: max(data.warped_max, 1e-6))
                    publish(frame.index, bitmap)
                }
            case .reference:
                break  // thumbnails keep the previous mode's appearance; the ref row always shows the ref preview
            }
        }
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Sint,
                                                                  width: tile_info.n_tiles_x,
                                                                  height: tile_info.n_tiles_y,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "Zero alignment (reference frame)"
        fill_with_zeros(texture)
        zero_alignment = texture
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
    
    /// Render one frame in the given mode. Called on a background thread.
    /// - `align_offset`: anchor offset (level-0 pixels) subtracted from all tile shifts.
    /// - `diff_white_override`: shared difference white point (already including the gain
    ///   multiplier); if nil, a per-frame white point (gain x this frame's mean difference) is used.
    func render(idx: Int, mode: InspectMode, alignment_scale: Int, align_offset: [Float],
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
            let texture = session.difference_texture(for: idx, match_exposure: match_exposure)
            let white: Float
            if let override = diff_white_override {
                white = override
            } else {
                white = diff_gain * texture_stats(texture).mean
            }
            let bitmap = render_gray_bitmap(texture, white_point: max(white, 1e-6), gain: 1.0, pool: 4)
            var info: String
            if diff_white_override != nil {
                info = String(format: "diff white point %.0f (shared: %.1f x median mean diff %.1f)", white, diff_gain, median_diff_mean)
            } else {
                info = String(format: "diff white point %.0f (per-frame: %.1f x this frame's mean diff)", white, diff_gain)
            }
            info += match_exposure ? " · brightness-matched to reference" : " · raw (--raw-diff)"
            if match_exposure {
                let m = session.exposure_match(for: idx)
                let mean = texture_stats(texture).mean
                let ev = -log2f(m.gain)
                info += String(format: " · mean diff %.1f · ΔEV %+.3f (gain %.3f, offset %+.1f)", mean, ev, m.gain, m.offset)
            }
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


private struct InspectorContentView: View {
    let session: InspectionSession
    @ObservedObject var coordinator: InspectionCoordinator
    @StateObject private var model: InspectorModel
    
    @State private var selected_idx: Int
    @State private var mode: InspectMode = .alignment
    @State private var align_shared = true
    @State private var align_manual_scale: Double = 32
    @State private var diff_shared = true
    @State private var diff_gain: Double = 4.0
    @State private var match_exposure = true
    @State private var anchor: AnchorPoint?
    @State private var rendered: NSImage?
    @State private var rendered_info: String = ""
    @State private var rendering = false
    @State private var render_generation = 0
    @State private var last_thumb_params = ""
    @State private var zoom: CGFloat = 1
    @State private var zoom_base: CGFloat = 1
    @State private var key_monitor: Any?
    @State private var list_proxy: ScrollViewProxy?
    
    init(session: InspectionSession, coordinator: InspectionCoordinator) {
        self.session = session
        self.coordinator = coordinator
        _model = StateObject(wrappedValue: InspectorModel(session: session))
        _selected_idx = State(initialValue: min(session.ref_idx + 1, session.frames.count - 1))
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
        .onChange(of: align_shared) { _ in schedule_render() }
        .onChange(of: align_manual_scale) { _ in schedule_render() }
        .onChange(of: diff_shared) { _ in schedule_render() }
        .onChange(of: diff_gain) { _ in schedule_render() }
        .onChange(of: match_exposure) { _ in schedule_render() }
        .onChange(of: model.calibrated) { _ in schedule_render() }
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
            .frame(width: 440)
            
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.frames, id: \.index) { frame in
                        FrameRow(frame: frame, selected: frame.index == selected_idx,
                                 thumbnail: model.thumbnails[frame.index])
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected_idx = frame.index
                            }
                            .id(frame.index)
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
    
    // MARK: image area
    
    /// size and position (inside the container) of the fitted image content (letterbox-aware)
    func content_rect(container: CGSize) -> (origin: CGPoint, size: CGSize) {
        let content_width: CGFloat, content_height: CGFloat
        if mode.is_alignment, let tile_info = reference_tile_info {
            content_width = CGFloat(tile_info.n_tiles_x)
            content_height = CGFloat(tile_info.n_tiles_y)
        } else {
            content_width = CGFloat(session.ref_texture_cropped.width)
            content_height = CGFloat(session.ref_texture_cropped.height)
        }
        let scale = min(container.width / content_width, container.height / content_height)
        let width = content_width * scale
        let height = content_height * scale
        return (CGPoint(x: (container.width - width) / 2, y: (container.height - height) / 2),
                CGSize(width: width, height: height))
    }
    
    private var image_area: some View {
        GeometryReader { geo in
            let container = CGSize(width: geo.size.width * zoom, height: geo.size.height * zoom)
            ZStack(alignment: .bottomTrailing) {
                if let image = rendered {
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(mode.is_alignment ? .none : .high)
                                .aspectRatio(contentMode: .fit)
                            if let a = anchor, mode.is_alignment {
                                let rect = content_rect(container: container)
                                AnchorMarker(u: a.u, v: a.v, origin: rect.origin, size: rect.size)
                            }
                        }
                        .frame(width: container.width, height: container.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            set_anchor(location: value.location, container: container)
                        })
                    }
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
            .gesture(MagnificationGesture()
                .onChanged { value in zoom = min(max(zoom_base * value, 1), 16) }
                .onEnded { _ in zoom_base = zoom })
            .onTapGesture(count: 2) {
                zoom = 1
                zoom_base = 1
            }
        }
    }
    
    /// Set the anchor point from a click on the image. The fractional position identifies the
    /// scene point (identical in all frames, since every frame is warped to the reference); the
    /// tile grid cell under it provides the per-frame shift that is subtracted from the field.
    private func set_anchor(location: CGPoint, container: CGSize) {
        let rect = content_rect(container: container)
        let u = min(max((location.x - rect.origin.x) / rect.size.width, 0), 1)
        let v = min(max((location.y - rect.origin.y) / rect.size.height, 0), 1)
        
        guard let tile_info = reference_tile_info else { return }
        let n_tiles_x = tile_info.n_tiles_x
        let n_tiles_y = tile_info.n_tiles_y
        
        var tile_x: Int
        var tile_y: Int
        if mode.is_alignment {
            // click on the tile-grid visualization: one bitmap pixel = one tile
            tile_x = min(max(Int((u * CGFloat(n_tiles_x) - 0.5).rounded()), 0), n_tiles_x - 1)
            tile_y = min(max(Int((v * CGFloat(n_tiles_y) - 0.5).rounded()), 0), n_tiles_y - 1)
        } else {
            // click on a photo mode: map to level-0 pixels, then to tile grid coordinates
            // (tile ix centers at level-0 x = (ix + 1) * tile_size / 2, see warp_texture_bayer)
            let downscale = Double(selected_frame.downscale_factor)
            let width_l0 = Double(session.ref_texture_cropped.width) / downscale
            let height_l0 = Double(session.ref_texture_cropped.height) / downscale
            let half_tile = Double(tile_info.tile_size) / 2
            let gx = (u * width_l0 + 0.5) / half_tile - 1
            let gy = (v * height_l0 + 0.5) / half_tile - 1
            tile_x = min(max(Int(gx.rounded()), 0), n_tiles_x - 1)
            tile_y = min(max(Int(gy.rounded()), 0), n_tiles_y - 1)
        }
        anchor = AnchorPoint(u: u, v: v, tile_x: tile_x, tile_y: tile_y)
        schedule_render()
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
                Text("↑/↓ change frame · click sets anchor · scroll/pinch to zoom, double-click resets")
                    .font(.system(size: 10)).opacity(0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: merge bar
    
    private var merge_bar: some View {
        HStack {
            Text("Merging discards the inspection view and runs the full alignment + merge pipeline.")
                .font(.system(size: 11))
                .opacity(0.6)
            Spacer()
            Button(action: {
                guard let handler = coordinator.merge_handler, let session = coordinator.session else { return }
                let urls = session.frames.map { $0.url }
                coordinator.dismiss()
                // let the inspection view (and its burst textures) be released before the merge reloads everything
                DispatchQueue.main.async { handler(urls) }
            }, label: {
                Text("Merge into image")
            })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: keyboard navigation
    
    private func install_key_monitor() {
        guard key_monitor == nil else { return }
        key_monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handle_key_down(event)
        }
    }
    
    private func handle_key_down(_ event: NSEvent) -> NSEvent? {
        guard let window = coordinator.window, event.window === window else { return event }
        // don't hijack keys while text input has focus
        if let responder = window.firstResponder, responder is NSTextView || responder is NSText {
            return event
        }
        switch event.keyCode {
        case 125:  // down arrow
            move_selection(+1)
            return nil
        case 126:  // up arrow
            move_selection(-1)
            return nil
        default:
            return event
        }
    }
    
    private func move_selection(_ delta: Int) {
        let next = min(max(selected_idx + delta, 0), session.frames.count - 1)
        if next != selected_idx {
            selected_idx = next
            list_proxy?.scrollTo(next, anchor: .center)
        }
    }
    
    // MARK: rendering
    
    private func schedule_render() {
        update_thumbnails()
        
        render_generation += 1
        let generation = render_generation
        rendering = true
        let idx = selected_idx
        let mode = self.mode
        let alignment_scale = align_shared ? model.alignment_scale : max(Int(align_manual_scale), 1)
        var align_offset: [Float] = [0.0, 0.0]
        if mode.is_alignment, let a = anchor {
            align_offset = model.alignment_offset(for: idx, tile_x: a.tile_x, tile_y: a.tile_y)
        }
        var diff_white: Float? = nil
        if mode == .difference && diff_shared && match_exposure && model.calibrated {
            diff_white = Float(diff_gain) * model.median_diff_mean
        }
        let gain = Float(diff_gain)
        let match = match_exposure
        DispatchQueue.global().async {
            autoreleasepool {
                let result = model.render(idx: idx, mode: mode, alignment_scale: alignment_scale,
                                          align_offset: align_offset, diff_white_override: diff_white,
                                          diff_gain: gain, match_exposure: match)
                let image = NSImage(size: NSSize(width: result.bitmap.pixelsWide, height: result.bitmap.pixelsHigh))
                image.addRepresentation(result.bitmap)
                DispatchQueue.main.async {
                    guard generation == self.render_generation else { return }
                    self.rendered = image
                    self.rendered_info = result.info
                    self.rendering = false
                }
            }
        }
    }
    
    /// Regenerate the frame-list thumbnails if the parameters they depend on changed.
    private func update_thumbnails() {
        guard mode != .reference else { return }
        let alignment_scale = align_shared ? model.alignment_scale : max(Int(align_manual_scale), 1)
        let params = "\(mode.rawValue)|\(alignment_scale)|\(anchor.map { "\($0.tile_x),\($0.tile_y)" } ?? "none")|\(mode == .difference ? diff_gain : 0)|\(model.calibrated)"
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


/// One row of the frame list: alignment thumbnail, frame number, file name, REF badge.
private struct FrameRow: View {
    let frame: InspectionFrame
    let selected: Bool
    let thumbnail: NSImage?
    
    var body: some View {
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
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
    }
}
