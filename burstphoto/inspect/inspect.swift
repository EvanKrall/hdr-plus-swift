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
    
    /// Re-render the warped comparison texture of one frame (cropped to the original frame).
    func aligned_texture(for idx: Int) -> MTLTexture {
        let frame = frames[idx]
        if frame.is_reference {
            return ref_texture_cropped
        }
        let exposure_diff = exposure_bias[ref_idx] - exposure_bias[idx]
        let comp_texture = prepare_texture(textures[idx], hotpixel_weight_texture, pad_x, pad_x, pad_y, pad_y,
                                           exposure_diff, black_level[idx], mosaic_pattern_width)
        let warped_texture = warp_texture(comp_texture, frame.alignment_texture!, frame.tile_info!, frame.downscale_factor)
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
    var frames: [InspectionFrame] = []
    for comp_idx in 0..<textures.count {
        
        if comp_idx == ref_idx {
            frames.append(InspectionFrame(index: comp_idx, url: image_urls[comp_idx], is_reference: true,
                                          alignment_texture: nil, tile_info: nil,
                                          downscale_factor: downscale_factor_array[0], stats: nil))
            if let progress = progress { DispatchQueue.main.async { progress.int += Int(80000000/Double(textures.count)) } }
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
        if let progress = progress { DispatchQueue.main.async { progress.int += Int(80000000/Double(textures.count)) } }
    }
    
    return InspectionSession(frames: frames,
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
}
