/**
 Built-in verification tests for the alignment inspection pipeline (see inspect/inspect.swift and
 viz/visualize.swift). Run with: burstphoto-cli selftest

 The tests use synthetic textures with known ground truth:
 - a noise texture and a shifted copy of it are aligned; the recovered alignment field and the
   residual after warping are compared against the known shift
 - the visualization kernels are checked against expected color values
 No input files are required.
 */
import Foundation
import MetalPerformanceShaders


/// Create an r32Float texture with shared storage from CPU-side float data (row-major).
func make_float_texture(_ data: [Float], _ width: Int, _ height: Int, label: String = "Selftest texture") -> MTLTexture {
    
    precondition(data.count == width * height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)!
    texture.label = label
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
    return texture
}


/// Deterministic pseudo-random floats in [0, 1].
func generate_noise(_ width: Int, _ height: Int, seed: UInt64) -> [Float] {
    
    var state = seed &* 2 &+ 1
    var data = [Float](repeating: 0.0, count: width * height)
    for i in 0..<(width * height) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        data[i] = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
    }
    return data
}


/// comp(x, y) = ref(x - dx, y - dy), zero-filled outside. After alignment, the comparison texture
/// should report a shift of (dx, dy) in full-resolution pixels and its warped version should equal
/// the reference texture (see warp_texture: out(x) = comp(x + alignment)).
func shifted_copy(_ ref_texture: MTLTexture, dx: Int, dy: Int) -> MTLTexture {
    
    let width = ref_texture.width
    let height = ref_texture.height
    var ref_data = [Float](repeating: 0.0, count: width * height)
    ref_texture.getBytes(&ref_data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    
    var comp_data = [Float](repeating: 0.0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let sx = x - dx
            let sy = y - dy
            if (sx >= 0) && (sx < width) && (sy >= 0) && (sy < height) {
                comp_data[y * width + x] = ref_data[sy * width + sx]
            }
        }
    }
    return make_float_texture(comp_data, width, height, label: "Selftest shifted copy")
}


/// Create an rg16Sint alignment texture filled with per-tile shifts given as [dx0, dy0, dx1, dy1, ...].
func make_alignment_texture(_ texels: [Int16], _ n_tiles_x: Int, _ n_tiles_y: Int) -> MTLTexture {
    
    precondition(texels.count == n_tiles_x * n_tiles_y * 2)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Sint, width: n_tiles_x, height: n_tiles_y, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)!
    texture.label = "Selftest alignment texture"
    texture.replace(region: MTLRegionMake2D(0, 0, n_tiles_x, n_tiles_y), mipmapLevel: 0, withBytes: texels, bytesPerRow: n_tiles_x * 4)
    return texture
}


struct Selftest {
    var failures = 0
    
    mutating func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("PASS  " + name)
        } else {
            print("FAIL  " + name + (detail.isEmpty ? "" : "  [" + detail + "]"))
            failures += 1
        }
    }
}


func run_selftest() -> Bool {
    
    var test = Selftest()
    
    // ------------------------------------------------------------------
    // 0. half -> float conversion and rg16Sint readback round trip
    // ------------------------------------------------------------------
    test.check("half_to_float(0x0000) == 0.0", half_to_float(0x0000) == 0.0)
    test.check("half_to_float(0x3C00) == 1.0", half_to_float(0x3C00) == 1.0)
    test.check("half_to_float(0xBC00) == -1.0", half_to_float(0xBC00) == -1.0)
    test.check("half_to_float(0x3555) ≈ 0.33325", abs(half_to_float(0x3555) - 0.33325) < 0.001)
    
    let known_texels: [Int16] = [0, 0, -3, 4, 123, -45]
    let known_alignment = make_alignment_texture(known_texels, 3, 1)
    let roundtrip = read_alignment_texels(known_alignment)
    test.check("rg16Sint readback round trip", roundtrip == known_texels, "read back \(roundtrip)")
    let known_stats = alignment_stats(known_alignment)
    test.check("alignment_stats min/max", known_stats.min_dx == -3 && known_stats.max_dx == 123 && known_stats.min_dy == -45 && known_stats.max_dy == 4,
               "dx [\(known_stats.min_dx)..\(known_stats.max_dx)], dy [\(known_stats.min_dy)..\(known_stats.max_dy)]")
    
    // ------------------------------------------------------------------
    // 1. alignment correctness on a synthetic global shift
    // ------------------------------------------------------------------
    let width = 512
    let height = 512
    // alignment pyramid identical to the real pipeline for a 512 px Bayer image
    let downscale_factor_array = [2, 2, 2]
    let tile_size_array = [32, 16, 8]
    let search_dist_array = [2, 2, 2]
    let no_color_factors = [-1.0, -1.0, -1.0]
    
    let ref_texture = make_float_texture(generate_noise(width, height, seed: 42), width, height, label: "Selftest ref")
    
    let shift_x = 10
    let shift_y = -6   // in full-resolution pixels; expected alignment: (5, -3) in level-0 pixels
    let comp_texture = shifted_copy(ref_texture, dx: shift_x, dy: shift_y)
    
    let ref_pyramid = build_pyramid(ref_texture, downscale_factor_array, 0.0, no_color_factors)
    let output = align_texture_ex(ref_pyramid, comp_texture, downscale_factor_array, tile_size_array, search_dist_array, true, 0.0, no_color_factors)
    
    test.check("downscale factor reported", output.downscale_factor == 2)
    
    // tiles must recover the exact shift except near the borders: the shifted comparison texture
    // has no data outside the frame (a real burst is zero-padded), so tiles whose window touches
    // the zero region have ambiguous ground truth. Exclude two tile rings plus verify that the
    // clear majority of all tiles still reports the exact shift.
    let n_tiles_x = output.alignment_texture.width
    let n_tiles_y = output.alignment_texture.height
    let texels = read_alignment_texels(output.alignment_texture)
    let expected_dx = Int16(shift_x / downscale_factor_array[0])
    let expected_dy = Int16(shift_y / downscale_factor_array[0])
    var interior_exact = true
    for ty in 2..<(n_tiles_y - 2) {
        for tx in 2..<(n_tiles_x - 2) {
            if texels[2 * (ty * n_tiles_x + tx)] != expected_dx || texels[2 * (ty * n_tiles_x + tx) + 1] != expected_dy {
                interior_exact = false
            }
        }
    }
    test.check("interior tiles recover exact shift (\(expected_dx), \(expected_dy))", interior_exact,
               "interior texels deviate from expectation")
    if !interior_exact {
        print("    alignment grid (dx,dy), tiles x=0..\(n_tiles_x - 1), y=0..\(n_tiles_y - 1):")
        for ty in 0..<n_tiles_y {
            var row = "    "
            for tx in 0..<n_tiles_x {
                row += String(format: "(%3d,%3d) ", texels[2 * (ty * n_tiles_x + tx)], texels[2 * (ty * n_tiles_x + tx) + 1])
            }
            print(row)
        }
    }
    
    var exact_count = 0
    for ty in 0..<n_tiles_y {
        for tx in 0..<n_tiles_x {
            if texels[2 * (ty * n_tiles_x + tx)] == expected_dx && texels[2 * (ty * n_tiles_x + tx) + 1] == expected_dy {
                exact_count += 1
            }
        }
    }
    let exact_fraction = Double(exact_count) / Double(n_tiles_x * n_tiles_y)
    test.check("majority of tiles report exact shift", exact_fraction > 0.6, "exact fraction = \(exact_fraction)")
    
    let stats = alignment_stats(output.alignment_texture)
    test.check("stats contain the shift", stats.max_dx >= expected_dx && stats.min_dx <= expected_dx && stats.max_dy >= expected_dy && stats.min_dy <= expected_dy,
               "dx [\(stats.min_dx)..\(stats.max_dx)], dy [\(stats.min_dy)..\(stats.max_dy)]")
    
    // ------------------------------------------------------------------
    // 2. warped comparison texture vs. reference
    // ------------------------------------------------------------------
    // crop deep enough that the warp's bilinear blending cannot mix in the degenerate border tiles
    let margin = 128
    let ref_cropped = crop_texture(ref_texture, margin, margin, margin, margin)
    let aligned_cropped = crop_texture(output.aligned_texture, margin, margin, margin, margin)
    let residual = texture_stats(abs_difference(ref_cropped, aligned_cropped))
    test.check("warp residual is small", residual.mean < 0.01, "mean residual = \(residual.mean)")
    
    let unaligned_diff = texture_stats(abs_difference(ref_cropped, crop_texture(comp_texture, margin, margin, margin, margin)))
    test.check("difference detects misalignment", unaligned_diff.mean > 0.1, "mean diff of unaligned pair = \(unaligned_diff.mean)")
    test.check("aligned pair differs much less than unaligned pair", residual.mean * 10.0 < unaligned_diff.mean,
               "residual \(residual.mean) vs unaligned \(unaligned_diff.mean)")
    
    // ------------------------------------------------------------------
    // 3. alignment field visualization
    // ------------------------------------------------------------------
    let bitmap = bitmap_from_rgba8_texture(render_alignment_texture(output.alignment_texture, color_mode: .rgb_axes, scale: 5, block_size: 1))
    test.check("alignment bitmap size == tile grid", bitmap.pixelsWide == n_tiles_x && bitmap.pixelsHigh == n_tiles_y)
    
    // expected for texel (5, -3) with scale 5: R = 0.5+0.5*(5/5) = 1.0 -> 255, G = 0.5+0.5*(-3/5) = 0.2 -> 51
    let pixel = (tile_x: 7, tile_y: 7)
    let offset = (pixel.tile_y * bitmap.pixelsWide + pixel.tile_x) * 4
    let byte_r = Int(bitmap.bitmapData![offset])
    let byte_g = Int(bitmap.bitmapData![offset + 1])
    let byte_b = Int(bitmap.bitmapData![offset + 2])
    test.check("rgb axes color for (5, -3)", abs(byte_r - 255) <= 3 && abs(byte_g - 51) <= 3 && byte_b == 0,
               "got R \(byte_r) G \(byte_g) B \(byte_b)")
    
    // hsv flow mode: bright color for the shifted field
    let flow_bitmap = bitmap_from_rgba8_texture(render_alignment_texture(output.alignment_texture, color_mode: .hsv_flow, scale: 5, block_size: 1))
    let flow_offset = (pixel.tile_y * flow_bitmap.pixelsWide + pixel.tile_x) * 4
    let flow_magnitude = max(Int(flow_bitmap.bitmapData![flow_offset]), Int(flow_bitmap.bitmapData![flow_offset + 1]), Int(flow_bitmap.bitmapData![flow_offset + 2]))
    test.check("hsv flow is saturated for large shift", flow_magnitude >= 240, "max channel = \(flow_magnitude)")
    
    // zero alignment: rgb axes -> 50% gray, hsv flow -> black
    let zero_alignment = make_alignment_texture([Int16](repeating: 0, count: 16 * 16 * 2), 16, 16)
    let zero_rgb = bitmap_from_rgba8_texture(render_alignment_texture(zero_alignment, color_mode: .rgb_axes, scale: 4, block_size: 1))
    let zero_offset = (8 * zero_rgb.pixelsWide + 8) * 4
    let zero_r = Int(zero_rgb.bitmapData![zero_offset])
    let zero_g = Int(zero_rgb.bitmapData![zero_offset + 1])
    test.check("zero shift is 50% gray (rgb axes)", abs(zero_r - 128) <= 3 && abs(zero_g - 128) <= 3, "got R \(zero_r) G \(zero_g)")
    
    let zero_flow = bitmap_from_rgba8_texture(render_alignment_texture(zero_alignment, color_mode: .hsv_flow, scale: 4, block_size: 1))
    let zero_flow_offset = (8 * zero_flow.pixelsWide + 8) * 4
    let zero_flow_r = Int(zero_flow.bitmapData![zero_flow_offset])
    test.check("zero shift is black (hsv flow)", zero_flow_r <= 5, "got R \(zero_flow_r)")
    
    // anchor-relative rendering: subtracting a texel's own shift makes that tile 50% gray
    var uniform_values = [Int16]()
    for _ in 0..<16 * 16 { uniform_values.append(contentsOf: [6, -2]) }
    let uniform_alignment = make_alignment_texture(uniform_values, 16, 16)
    let anchored_bitmap = bitmap_from_rgba8_texture(render_alignment_texture(uniform_alignment, color_mode: .rgb_axes, scale: 4, block_size: 1, offset: [6.0, -2.0]))
    let anchored_offset = (8 * anchored_bitmap.pixelsWide + 8) * 4
    let anchored_r = Int(anchored_bitmap.bitmapData![anchored_offset])
    let anchored_g = Int(anchored_bitmap.bitmapData![anchored_offset + 1])
    test.check("anchor-relative rendering zeroes the anchored tile", abs(anchored_r - 128) <= 3 && abs(anchored_g - 128) <= 3,
               "got R \(anchored_r) G \(anchored_g)")
    
    // bilinear (block_size > 1) rendering keeps the aspect ratio
    let smooth_bitmap = bitmap_from_rgba8_texture(render_alignment_texture(zero_alignment, color_mode: .rgb_axes, scale: 4, block_size: 4))
    test.check("block rendering size", smooth_bitmap.pixelsWide == 16 * 4 && smooth_bitmap.pixelsHigh == 16 * 4)
    
    // ------------------------------------------------------------------
    // 4. gray tonemapping and stats
    // ------------------------------------------------------------------
    let constant_texture = make_float_texture([Float](repeating: 0.25, count: width * height), width, height, label: "Selftest constant")
    let constant_stats = texture_stats(constant_texture)
    test.check("texture_stats of constant 0.25", abs(constant_stats.mean - 0.25) < 0.01 && abs(constant_stats.max - 0.25) < 0.01,
               "mean \(constant_stats.mean), max \(constant_stats.max)")
    
    let gray_bitmap = render_gray_bitmap(constant_texture, white_point: 0.5, gain: 1.0, pool: 1)
    let gray_offset = (height / 2 * gray_bitmap.pixelsWide + width / 2) * 4
    let gray_byte = Int(gray_bitmap.bitmapData![gray_offset])
    test.check("gray tonemap 0.25/0.5 -> mid gray", abs(gray_byte - 128) <= 3, "got \(gray_byte)")
    
    let pooled_bitmap = render_gray_bitmap(constant_texture, white_point: 1.0, gain: 1.0, pool: 4)
    let pooled_offset = (pooled_bitmap.pixelsHigh / 2 * pooled_bitmap.pixelsWide + pooled_bitmap.pixelsWide / 2) * 4
    let pooled_byte = Int(pooled_bitmap.bitmapData![pooled_offset])
    test.check("pooled gray tonemap 0.25/1.0 -> 64", abs(pooled_byte - 64) <= 3, "got \(pooled_byte)")
    
    // ------------------------------------------------------------------
    // 5. brightness matching (y = m*x + b) for difference images
    // ------------------------------------------------------------------
    // simulate a perfectly warped comparison frame that is 1.25x brighter than the reference with a
    // +0.02 pedestal (residual exposure error). Note: a brightness error this large would itself
    // degrade pyramid alignment (the alignment kernels clamp per-tile ratios to [0.9, 1.1]); here
    // only the difference stage is under test, so the comparison is constructed already aligned.
    var bright_data = [Float](repeating: 0.0, count: width * height)
    var ref_data = [Float](repeating: 0.0, count: width * height)
    ref_texture.getBytes(&ref_data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    for i in 0..<(width * height) {
        bright_data[i] = ref_data[i] * 1.25 + 0.02
    }
    let bright_texture = make_float_texture(bright_data, width, height, label: "Selftest bright comp")
    let bright_aligned = crop_texture(bright_texture, margin, margin, margin, margin)
    let bright_ref = crop_texture(ref_texture, margin, margin, margin, margin)
    
    let match = brightness_match(bright_ref, bright_aligned)
    test.check("brightness match recovers gain 0.8", abs(match.gain - 0.8) < 0.04, "gain = \(match.gain)")
    test.check("brightness match recovers offset", abs(match.offset + 0.016) < 0.01, "offset = \(match.offset)")
    
    let matched_diff = texture_stats(abs_difference(bright_ref, bright_aligned, gain: match.gain, offset: match.offset))
    let raw_diff = texture_stats(abs_difference(bright_ref, bright_aligned))
    test.check("matched residual much smaller than raw", matched_diff.mean < 0.01 && raw_diff.mean > 5.0 * max(matched_diff.mean, 0.001),
               "matched \(matched_diff.mean) vs raw \(raw_diff.mean)")
    
    // robust brightness match: ~70% of the values follow y = 0.8*x - 0.016 (small noise), the rest
    // are outliers spread over [0, 1]. The fit must follow the inliers, not the outliers.
    var robust_x: [Float] = []
    var robust_y: [Float] = []
    robust_x.reserveCapacity(2000)
    robust_y.reserveCapacity(2000)
    var rng_state: UInt64 = 12345
    func pseudo_random() -> Double {
        rng_state = rng_state &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng_state >> 11) / Double(1 << 53)
    }
    for i in 0..<2000 {
        let x = Float(0.1 + 0.8 * Double(i) / 1999.0)
        robust_x.append(x)
        if pseudo_random() < 0.7 {
            robust_y.append(0.8 * x - 0.016 + Float((pseudo_random() - 0.5) * 0.004))
        } else {
            robust_y.append(Float(pseudo_random()))
        }
    }
    let robust_fit = robust_brightness_match_values(robust_y, robust_x, tolerance: 0.01)
    test.check("robust brightness match ignores outliers", abs(robust_fit.gain - 0.8) < 0.03 && abs(robust_fit.offset + 0.016) < 0.01,
               "gain \(robust_fit.gain), offset \(robust_fit.offset), inlier fraction \(robust_fit.inlier_fraction)")
    test.check("robust brightness match inlier fraction", robust_fit.inlier_fraction > 0.6, "inlier fraction = \(robust_fit.inlier_fraction)")
    
    // signed difference coloring: comparison brighter than reference -> red, darker -> blue
    let signed_ref = make_float_texture([Float](repeating: 0.5, count: width * height), width, height, label: "Selftest signed ref")
    var signed_comp_data = [Float](repeating: 0.0, count: width * height)
    for y in 0..<height {
        let value: Float = y < height / 3 ? 0.6 : (y < 2 * height / 3 ? 0.4 : 0.5)
        for x in 0..<width {
            signed_comp_data[y * width + x] = value
        }
    }
    let signed_comp = make_float_texture(signed_comp_data, width, height, label: "Selftest signed comp")
    let signed_bitmap = render_signed_difference_bitmap(signed_ref, signed_comp, gain: 1.0, offset: 0.0, white_point: 0.1, pool: 1)
    func signed_pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * signed_bitmap.pixelsWide + x) * 4
        return (Int(signed_bitmap.bitmapData![offset]), Int(signed_bitmap.bitmapData![offset + 1]), Int(signed_bitmap.bitmapData![offset + 2]))
    }
    let brighter = signed_pixel(width / 2, height / 6)
    let darker = signed_pixel(width / 2, height / 2)
    let equal = signed_pixel(width / 2, 5 * height / 6)
    test.check("signed difference: brighter is red", brighter.r >= 250 && brighter.b <= 5, "got R \(brighter.r) B \(brighter.b)")
    test.check("signed difference: darker is blue", darker.b >= 250 && darker.r <= 5, "got R \(darker.r) B \(darker.b)")
    test.check("signed difference: equal is black", equal.r <= 5 && equal.b <= 5, "got R \(equal.r) B \(equal.b)")
    
    // ------------------------------------------------------------------
    print("")
    if test.failures == 0 {
        print("Selftest passed: all checks OK")
    } else {
        print("Selftest FAILED: \(test.failures) check(s) failed")
    }
    return test.failures == 0
}
