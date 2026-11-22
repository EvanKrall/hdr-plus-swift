/**
 Alignment inspection: aligns every comparison frame of a burst against the reference frame and
 exposes the alignment field and per-frame textures for visualization, without merging. This is the
 intermediate step between importing a burst and running the full align+merge pipeline.

 Data layout notes:
 - The alignment texture of each frame is an rg16Sint texture with one texel per tile, storing the
   tile shift (dx, dy) in pyramid level-0 pixels. Multiplied by the frame's downscale factor, these
   values become sensor-pixel shifts (see align/align.swift).
 - Only small artifacts (alignment textures, stats) are retained for every frame. Full-resolution
   textures (warped candidate, difference) are re-rendered on demand from the retained input
   textures, which are already in memory after loading the burst.
 */
import Foundation
import MetalPerformanceShaders
import Combine


/// Alignment result of a single comparison frame against the reference frame.
class InspectionFrame {
    let index: Int
    let url: URL
    let is_reference: Bool
    /// rg16Sint tile-grid texture (nil for the reference frame)
    let alignment_texture: MTLTexture?
    /// tile geometry of the finest pyramid level (nil for the reference frame)
    let tile_info: TileInfo?
    /// factor between the original texture and pyramid level 0 (usually the mosaic pattern width)
    let downscale_factor: Int
    let stats: AlignmentStats?
    
    init(index: Int, url: URL, is_reference: Bool, alignment_texture: MTLTexture?, tile_info: TileInfo?, downscale_factor: Int, stats: AlignmentStats?) {
        self.index = index
        self.url = url
        self.is_reference = is_reference
        self.alignment_texture = alignment_texture
        self.tile_info = tile_info
        self.downscale_factor = downscale_factor
        self.stats = stats
    }
}


/// Everything needed to render alignment visualizations of a burst on demand.
/// Parses the autofocus area of a Nikon NEF ("AFAreaXPosition/YPosition/Width/Height", stored in
/// the maker notes' AFInfo2 binary record; neither the DNG SDK nor ImageIO decode it — this is a
/// minimal re-implementation of what exiftool does). Returns the AF-area center and size in
/// pixels (y from top) plus the image dimensions the values are relative to; nil if unavailable.
func read_af_area(url: URL) -> (x: Int, y: Int, width: Int, height: Int, image_width: Int, image_height: Int)? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    func byte(_ o: Int) -> Int { o >= 0 && o < data.count ? Int(data[data.startIndex + o]) : -1 }
    func u16(_ o: Int, _ le: Bool) -> Int {
        let a = byte(o), b = byte(o + 1)
        return (a < 0 || b < 0) ? -1 : (le ? a | (b << 8) : (a << 8) | b)
    }
    func u32(_ o: Int, _ le: Bool) -> Int {
        let a = u16(o, le), b = u16(o + 2, le)
        return (a < 0 || b < 0) ? -1 : (le ? a | (b << 16) : (a << 16) | b)
    }
    let le = byte(0) == 0x49  // "II" = little endian, "MM" = big endian
    guard u16(2, le) == 42 else { return nil }
    func entries(_ off: Int) -> [(tag: Int, type: Int, count: Int, value_offset: Int)] {
        let count = u16(off, le)
        guard count > 0 && count < 1000 else { return [] }
        return (0..<count).map { i in
            let e = off + 2 + 12 * i
            return (u16(e, le), u16(e + 2, le), u32(e + 4, le), u32(e + 8, le))
        }
    }
    
    // IFD0 -> Exif IFD -> MakerNote; the Exif IFD also carries the active pixel dimensions
    var exif_ifd = -1
    for e in entries(u32(4, le)) where e.tag == 0x8769 { exif_ifd = e.value_offset }
    guard exif_ifd > 0 else { return nil }
    var pixel_width = -1, pixel_height = -1
    var maker_offset = -1
    for e in entries(exif_ifd) {
        if e.tag == 0x927c { maker_offset = e.value_offset }
        if e.tag == 0xa002, pixel_width < 0 { pixel_width = e.type == 4 ? u32(e.value_offset, le) : u16(e.value_offset, le) }
        if e.tag == 0xa003, pixel_height < 0 { pixel_height = e.type == 4 ? u32(e.value_offset, le) : u16(e.value_offset, le) }
    }
    guard maker_offset > 0, byte(maker_offset) == 0x4e else { return nil }  // "Nikon\0" signature
    
    // Nikon maker notes (version 0102+): "Nikon\0" + 4-char version + embedded TIFF header whose
    // IFD offsets are relative to the header itself
    let header = maker_offset + 10
    let maker_le = byte(header) == 0x49
    guard u16(header + 2, maker_le) == 42 else { return nil }
    let maker_ifd = header + u32(header + 4, maker_le)
    
    // AFInfo2 record: maker tag 0x00b7 on modern bodies, 0x0088 on older ones; starts with a
    // 4-character ASCII version like "0100" or "0401"
    for af_tag in [0x00b7, 0x0088] {
        guard let entry = entries(maker_ifd).first(where: { $0.tag == af_tag && $0.type == 7 }),
              entry.count >= 54, entry.value_offset >= 0 else { continue }
        let block = header + entry.value_offset
        let digits = (0..<4).map { byte(block + $0) }
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { continue }
        let version_major = (digits[0] - 0x30) * 10 + (digits[1] - 0x30)  // "0401" -> 4
        
        // all versions observed so far embed the tuple
        //   image width, image height, AF x, AF y (center), AF width, AF height  (u16)
        // somewhere in the record (offset 42 on Z 6 "0100"/"0300", 63 on Z 6_3 "0401") — scan for it
        var offset = 4
        while offset + 12 <= min(entry.count, 256) {
            let iw = u16(block + offset, maker_le), ih = u16(block + offset + 2, maker_le)
            let x = u16(block + offset + 4, maker_le), y = u16(block + offset + 6, maker_le)
            let w = u16(block + offset + 8, maker_le), h = u16(block + offset + 10, maker_le)
            if iw > 1000, ih > 1000,                      // plausible image size
               iw >= ih / 2, iw <= ih * 4,                 // sane sensor aspect
               x > 0, y > 0, x < iw, y < ih,              // center inside the image
               w > 0, h > 0, w <= iw, h <= ih {
                return (x, y, w, h, iw, ih)
            }
            offset += 2
        }
        
        if version_major <= 3 {
            // flat layout fallback — version[4], short, byte, byte, then x@8 y@10 w@12 h@14
            let x = u16(block + 8, maker_le), y = u16(block + 10, maker_le)
            let w = u16(block + 12, maker_le), h = u16(block + 14, maker_le)
            if x > 0, y > 0, w > 0, h > 0, w <= x * 2, h <= y * 2 {
                return (x, y, w, h, 0, 0)
            }
        }
    }
    return nil
}

/// A rectangular "subject" area, as fractions of the frame (origin top-left, x1/y1 included).
/// Dragged by the user in the inspector; derived from the AF point for automatic scoring.
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


/// Region of interest around the reference frame's autofocus area (the selected AF point doubled
/// in size, minimum 4% of the frame), as fractions of the frame. Nil if the camera recorded no
/// AF position (see read_af_area).
func af_subject_roi(session: InspectionSession) -> RoiRect? {
    guard let af = session.af_area, af.image_width > 0, af.image_height > 0 else { return nil }
    let image_w = CGFloat(af.image_width), image_h = CGFloat(af.image_height)
    let cx = CGFloat(af.x) / image_w
    let cy = CGFloat(af.y) / image_h
    let extent_w = max(CGFloat(af.width) / image_w * 2.0, 0.04)  // 2x the AF area, min 4% of frame
    let extent_h = max(CGFloat(af.height) / image_h * 2.0, 0.04)
    return RoiRect(x0: max(0, cx - extent_w / 2), y0: max(0, cy - extent_h / 2),
                   x1: min(1, cx + extent_w / 2), y1: min(1, cy + extent_h / 2))
}


/// Default subject area for automatic frame scoring: the region around the reference frame's
/// selected autofocus point (see af_subject_roi), or a centered rectangle covering half the
/// frame when the camera recorded no AF position.
func auto_burst_subject_roi(session: InspectionSession) -> RoiRect {
    if let roi = af_subject_roi(session: session) { return roi }
    return RoiRect(x0: 0.25, y0: 0.25, x1: 0.75, y1: 0.75)
}


/// Median of an already sorted array.
func median_of_sorted(_ values: [Double]) -> Double {
    if values.isEmpty { return 1.0 }
    let mid = values.count / 2
    return values.count % 2 == 1 ? values[mid] : 0.5 * (values[mid - 1] + values[mid])
}


/// Variation of the tile alignment field inside a rectangle (fractions of the frame, y from
/// top): each tile's shift is compared to the per-axis median shift of the region, combined to a
/// magnitude, and averaged over all tiles in the region (no outlier exclusion — the
/// worst-matching tiles are the signal). Only tiles fully inside the rectangle are used when
/// there are at least four of them (boundary tiles mix subject and background motion);
/// otherwise overlapping tiles are used. Returns the score in level-0 pixels (lower = more rigid
/// mapping to the reference); nil if the rectangle is smaller than a few tiles.
func alignment_variation_in_roi(texels: [Int16], alignment_width: Int, alignment_height: Int, tile_size: Int, downscale_factor: Int, roi: RoiRect, frame_width: Int, frame_height: Int, pad_x: Int, pad_y: Int) -> Float? {
    
    guard texels.count >= alignment_width * alignment_height * 2 else { return nil }
    let n_tiles_x = alignment_width, n_tiles_y = alignment_height
    // tile geometry: the alignment grid spans the PADDED frame at 1/downscale scale; tile ix
    // centers at level-0 x = (ix + 1) * tile_size / 2 (see warp_texture_bayer). Frame pixels
    // therefore map to level-0 pixels as (x + pad) / downscale.
    let downscale = CGFloat(downscale_factor)
    let half_tile = CGFloat(tile_size) / 2
    let n = roi.normalized()
    let x0 = (n.x0 * CGFloat(frame_width) + CGFloat(pad_x)) / downscale
    let x1 = (n.x1 * CGFloat(frame_width) + CGFloat(pad_x)) / downscale
    let y0 = (n.y0 * CGFloat(frame_height) + CGFloat(pad_y)) / downscale
    let y1 = (n.y1 * CGFloat(frame_height) + CGFloat(pad_y)) / downscale
    
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


class InspectionSession: ObservableObject {
    /// one entry per frame of the burst, in the order the images were passed in
    let frames: [InspectionFrame]
    let ref_idx: Int
    /// reference texture, prepared (hot pixels corrected, exposure equalized) and cropped to the original frame
    let ref_texture_cropped: MTLTexture
    /// all input textures of the burst (r16Uint mosaic), as loaded from disk
    let textures: [MTLTexture]
    let hotpixel_weight_texture: MTLTexture
    let mosaic_pattern_width: Int
    let black_level: [[Int]]
    let exposure_bias: [Int]
    /// padding used to extend the frame for the alignment
    let pad_x: Int
    let pad_y: Int
    let color_factors: [[Double]]
    /// autofocus area of the reference frame (x/y center + size in pixels, y from top, relative
    /// to image_width × image_height), parsed from the file's Nikon maker notes; nil if unavailable
    fileprivate(set) var af_area: (x: Int, y: Int, width: Int, height: Int, image_width: Int, image_height: Int)? = nil
    /// cached per-frame brightness match (gain, offset), computed on demand
    private var match_cache: [Int: (gain: Float, offset: Float)] = [:]
    
    init(frames: [InspectionFrame], ref_idx: Int, ref_texture_cropped: MTLTexture, textures: [MTLTexture],
         hotpixel_weight_texture: MTLTexture, mosaic_pattern_width: Int, black_level: [[Int]],
         exposure_bias: [Int], pad_x: Int, pad_y: Int, color_factors: [[Double]]) {
        self.frames = frames
        self.ref_idx = ref_idx
        self.ref_texture_cropped = ref_texture_cropped
        self.textures = textures
        self.hotpixel_weight_texture = hotpixel_weight_texture
        self.mosaic_pattern_width = mosaic_pattern_width
        self.black_level = black_level
        self.exposure_bias = exposure_bias
        self.pad_x = pad_x
        self.pad_y = pad_y
        self.color_factors = color_factors
    }
    
    /// Re-prepare the comparison texture of one frame (hot pixels corrected, black level and
    /// exposure equalized). If `padded` is false, the padding added for the alignment is cropped
    /// away again. The reference frame is already prepared and cropped (use ref_texture_cropped).
    func prepared_texture(for idx: Int, padded: Bool) -> MTLTexture {
        let texture = prepare_texture(textures[idx], hotpixel_weight_texture, pad_x, pad_x, pad_y, pad_y,
                                      exposure_bias[ref_idx] - exposure_bias[idx], black_level[idx], mosaic_pattern_width)
        return padded ? texture : crop_texture(texture, pad_x, pad_x, pad_y, pad_y)
    }
    
    /// Re-render the warped comparison texture of one frame (cropped to the original frame).
    func aligned_texture(for idx: Int) -> MTLTexture {
        let frame = frames[idx]
        if frame.is_reference {
            return ref_texture_cropped
        }
        let warped_texture = warp_texture(prepared_texture(for: idx, padded: true), frame.alignment_texture!, frame.tile_info!, frame.downscale_factor)
        return crop_texture(warped_texture, pad_x, pad_x, pad_y, pad_y)
    }
    
    /// Brightness match between the reference texture and the warped comparison texture
    /// (aligned_matched = gain * aligned + offset ≈ ref), estimated by linear regression.
    func exposure_match(for idx: Int) -> (gain: Float, offset: Float) {
        if let cached = match_cache[idx] {
            return cached
        }
        let match = brightness_match(ref_texture_cropped, aligned_texture(for: idx))
        match_cache[idx] = match
        return match
    }
    
    /// Store a precomputed brightness match in the cache (used by the inspection UI, which
    /// computes the matches for all frames in a background calibration pass).
    func store_match(for idx: Int, gain: Float, offset: Float) {
        match_cache[idx] = (gain: gain, offset: offset)
    }
    
    /// Per-pixel absolute difference between the reference texture and the warped comparison
    /// texture. By default the comparison texture is brightness-matched to the reference first,
    /// so that the difference shows motion/occlusion instead of residual exposure differences.
    func difference_texture(for idx: Int, match_exposure: Bool = true) -> MTLTexture {
        let aligned = aligned_texture(for: idx)
        if match_exposure {
            let match = exposure_match(for: idx)
            return abs_difference(ref_texture_cropped, aligned, gain: match.gain, offset: match.offset)
        }
        return abs_difference(ref_texture_cropped, aligned)
    }
}


/// Align every frame of a burst against the reference frame and return an inspection session that
/// can render alignment fields and difference images on demand. No merging is performed.
///
/// The alignment setup (padding, pyramid, per-frame alignment call) is kept identical to
/// align_merge_spatial_domain() in merge/spatial.swift, so the visualization shows exactly the
/// alignment that the merging would use.
func perform_alignment_inspection(image_urls: [URL], progress: ProcessingProgress?, tile_size: String = "Medium", search_distance: String = "Medium", tmp_dir: String) throws -> InspectionSession {
    
    let burst = try load_and_prepare_burst(image_urls: image_urls, progress: progress, tmp_dir: tmp_dir)
    let textures = burst.textures
    let ref_idx = burst.ref_idx
    let mosaic_pattern_width = burst.mosaic_pattern_width
    
    // set alignment params (identical to align_merge_spatial_domain)
    let texture_width_orig = textures[ref_idx].width
    let texture_height_orig = textures[ref_idx].height
    let min_image_dim = min(texture_width_orig, texture_height_orig)
    var downscale_factor_array = [mosaic_pattern_width]
    var search_dist_array = [2]
    var tile_size_array = [tile_size_dict[tile_size]!]
    var res = min_image_dim / downscale_factor_array[0]
    
    while (res > search_distance_dict[search_distance]!) {
        downscale_factor_array.append(2)
        search_dist_array.append(2)
        tile_size_array.append(max(tile_size_array.last!/2, 8))
        res /= 2
    }
    
    // calculate padding for extension of the image frame with zeros (identical to align_merge_spatial_domain)
    let tile_factor = Int(tile_size_array.last!) * downscale_factor_array.reduce(1, *)
    
    var pad_align_x = Int(ceil(Float(texture_width_orig)/Float(tile_factor)))
    pad_align_x = (pad_align_x*Int(tile_factor) - texture_width_orig)/2
    
    var pad_align_y = Int(ceil(Float(texture_height_orig)/Float(tile_factor)))
    pad_align_y = (pad_align_y*Int(tile_factor) - texture_height_orig)/2
    
    // hot pixel correction (same defaults as the merging pipeline)
    let hotpixel_weight_texture_descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: texture_width_orig, height: texture_height_orig, mipmapped: false)
    hotpixel_weight_texture_descriptor.usage = [.shaderRead, .shaderWrite]
    hotpixel_weight_texture_descriptor.storageMode = .private
    let hotpixel_weight_texture = device.makeTexture(descriptor: hotpixel_weight_texture_descriptor)!
    hotpixel_weight_texture.label = "Hotpixel weight texture"
    fill_with_zeros(hotpixel_weight_texture)
    find_hotpixels(textures, hotpixel_weight_texture, burst.black_level, burst.ISO_exposure_time, 13.0, mosaic_pattern_width)
    
    // prepare reference texture and build the reference pyramid
    let ref_texture = prepare_texture(textures[ref_idx], hotpixel_weight_texture, pad_align_x, pad_align_x, pad_align_y, pad_align_y, 0, burst.black_level[ref_idx], mosaic_pattern_width)
    let ref_texture_cropped = crop_texture(ref_texture, pad_align_x, pad_align_x, pad_align_y, pad_align_y)
    
    var black_level_mean = Double(burst.black_level[ref_idx].reduce(0, +)) / Double(burst.black_level[ref_idx].count)
    
    let ref_pyramid = build_pyramid(ref_texture, downscale_factor_array, black_level_mean, burst.color_factors[ref_idx])
    
    // align every comparison frame
    // (hoisted out of the progress closures below: a closure capturing `textures` would retain
    // every input texture on the never-draining main queue of a CLI process — the CLI memory leak)
    let progress_units_per_frame = Int(80000000/Double(textures.count))
    var frames: [InspectionFrame] = []
    for comp_idx in 0..<textures.count {
        
        if comp_idx == ref_idx {
            frames.append(InspectionFrame(index: comp_idx, url: image_urls[comp_idx], is_reference: true,
                                          alignment_texture: nil, tile_info: nil,
                                          downscale_factor: downscale_factor_array[0], stats: nil))
            if let progress = progress { DispatchQueue.main.async { progress.int += progress_units_per_frame } }
            continue
        }
        
        // prepare comparison texture by correcting hot pixels, equalizing exposure and extending the texture
        let comp_texture = prepare_texture(textures[comp_idx], hotpixel_weight_texture, pad_align_x, pad_align_x, pad_align_y, pad_align_y, (burst.exposure_bias[ref_idx]-burst.exposure_bias[comp_idx]), burst.black_level[comp_idx], mosaic_pattern_width)
        
        black_level_mean = Double(burst.black_level[comp_idx].reduce(0, +)) / Double(burst.black_level[comp_idx].count)
        
        let output = align_texture_ex(ref_pyramid, comp_texture, downscale_factor_array, tile_size_array, search_dist_array, (burst.exposure_bias[comp_idx]==burst.exposure_bias[ref_idx]), black_level_mean, burst.color_factors[comp_idx])
        let stats = alignment_stats(output.alignment_texture)
        
        frames.append(InspectionFrame(index: comp_idx, url: image_urls[comp_idx], is_reference: false,
                                      alignment_texture: output.alignment_texture, tile_info: output.tile_info,
                                      downscale_factor: output.downscale_factor, stats: stats))
        if let progress = progress { DispatchQueue.main.async { progress.int += progress_units_per_frame } }
    }
    
    let session = InspectionSession(frames: frames,
                             ref_idx: ref_idx,
                             ref_texture_cropped: ref_texture_cropped,
                             textures: textures,
                             hotpixel_weight_texture: hotpixel_weight_texture,
                             mosaic_pattern_width: mosaic_pattern_width,
                             black_level: burst.black_level,
                             exposure_bias: burst.exposure_bias,
                             pad_x: pad_align_x,
                             pad_y: pad_align_y,
                             color_factors: burst.color_factors)
    session.af_area = read_af_area(url: image_urls[ref_idx])
    return session
}
