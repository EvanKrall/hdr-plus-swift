/**
 Functions for visualizing alignment data. Used by the alignment inspection
 (see inspect/inspect.swift) and its command-line interface.
 */
import Foundation
import MetalPerformanceShaders
import AppKit

let render_alignment_color_state     = create_pipeline(with_function_name: "render_alignment_color", and_label: "Render Alignment Color")
let abs_difference_state             = create_pipeline(with_function_name: "abs_difference",         and_label: "Abs Difference")
let gray_to_rgba8_state              = create_pipeline(with_function_name: "gray_to_rgba8",          and_label: "Gray to RGBA8")


/// How the alignment field is mapped to colors.
enum AlignmentColorMode {
    case rgb_axes    // R = +x shift, G = +y shift, zero shift = 50% gray
    case hsv_flow    // hue = shift direction, brightness = shift magnitude, zero shift = black
}


/// Summary of the per-tile shifts stored in an alignment texture (all values in level-0 pixels;
/// multiply by the alignment's downscale factor to get sensor pixels).
struct AlignmentStats {
    let min_dx: Int
    let max_dx: Int
    let min_dy: Int
    let max_dy: Int
    let mean_magnitude: Double
    
    /// Largest absolute shift component in the field.
    var max_abs_shift: Int {
        return max(max(abs(min_dx), abs(max_dx)), max(abs(min_dy), abs(max_dy)))
    }
}


/// Copy the content of a texture into a shared CPU-accessible buffer and wait for completion.
func blit_texture_to_shared_buffer(_ texture: MTLTexture, bytes_per_pixel: Int) -> MTLBuffer {
    
    let bytes_per_row = texture.width * bytes_per_pixel
    let buffer = device.makeBuffer(length: bytes_per_row * texture.height, options: .storageModeShared)!
    
    let command_buffer = command_queue.makeCommandBuffer()!
    command_buffer.label = "Blit Texture to Shared Buffer"
    let blit_encoder = command_buffer.makeBlitCommandEncoder()!
    blit_encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: bytes_per_row,
                      destinationBytesPerImage: bytes_per_row * texture.height)
    blit_encoder.endEncoding()
    command_buffer.commit()
    command_buffer.waitUntilCompleted()
    
    return buffer
}


/// Read all texels of an rg16Sint alignment texture into a flat [dx0, dy0, dx1, dy1, ...] array.
func read_alignment_texels(_ alignment: MTLTexture) -> [Int16] {
    
    precondition(alignment.pixelFormat == .rg16Sint)
    let buffer = blit_texture_to_shared_buffer(alignment, bytes_per_pixel: 4)
    let count = alignment.width * alignment.height * 2
    let pointer = buffer.contents().bindMemory(to: Int16.self, capacity: count)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
}


/// Compute summary statistics of an alignment texture (values in level-0 pixels).
func alignment_stats(_ alignment: MTLTexture) -> AlignmentStats {
    
    let texels = read_alignment_texels(alignment)
    let n_tiles = alignment.width * alignment.height
    
    var min_dx = Int.max, max_dx = -Int.max
    var min_dy = Int.max, max_dy = -Int.max
    var magnitude_sum = 0.0
    for i in 0..<n_tiles {
        let dx = Int(texels[2*i])
        let dy = Int(texels[2*i + 1])
        min_dx = min(min_dx, dx); max_dx = max(max_dx, dx)
        min_dy = min(min_dy, dy); max_dy = max(max_dy, dy)
        magnitude_sum += sqrt(Double(dx*dx + dy*dy))
    }
    
    return AlignmentStats(min_dx: min_dx, max_dx: max_dx, min_dy: min_dy, max_dy: max_dy,
                          mean_magnitude: magnitude_sum / Double(n_tiles))
}


/// Render an alignment texture to a small rgba8Unorm texture (one tile per block_size x block_size
/// pixels) that can be read back on the CPU. The `scale` parameter (in level-0 pixels) defines the
/// shift that is mapped to full saturation. `offset` (level-0 pixels) is subtracted from every
/// tile shift before the color mapping (see the kernel documentation).
func render_alignment_texture(_ alignment: MTLTexture, color_mode: AlignmentColorMode, scale: Int, block_size: Int = 8, offset: [Float] = [0.0, 0.0]) -> MTLTexture {
    
    precondition(alignment.pixelFormat == .rg16Sint)
    
    let output_descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                     width: alignment.width * block_size,
                                                                     height: alignment.height * block_size,
                                                                     mipmapped: false)
    output_descriptor.usage = [.shaderRead, .shaderWrite]
    output_descriptor.storageMode = .shared
    let output_texture = device.makeTexture(descriptor: output_descriptor)!
    output_texture.label = "Alignment visualization"
    
    let command_buffer = command_queue.makeCommandBuffer()!
    command_buffer.label = "Render Alignment Color"
    let command_encoder = command_buffer.makeComputeCommandEncoder()!
    command_encoder.label = command_buffer.label
    command_encoder.setComputePipelineState(render_alignment_color_state)
    let threads_per_grid = MTLSize(width: output_texture.width, height: output_texture.height, depth: 1)
    let threads_per_thread_group = get_threads_per_thread_group(render_alignment_color_state, threads_per_grid)
    command_encoder.setTexture(alignment, index: 0)
    command_encoder.setTexture(output_texture, index: 1)
    command_encoder.setBytes([Int32(color_mode == .rgb_axes ? 0 : 1)], length: MemoryLayout<Int32>.stride, index: 0)
    command_encoder.setBytes([Float32(max(scale, 1))], length: MemoryLayout<Float32>.stride, index: 1)
    command_encoder.setBytes([Int32(block_size)], length: MemoryLayout<Int32>.stride, index: 2)
    command_encoder.setBytes(offset, length: MemoryLayout<Float>.stride * 2, index: 3)
    command_encoder.dispatchThreads(threads_per_grid, threadsPerThreadgroup: threads_per_thread_group)
    command_encoder.endEncoding()
    command_buffer.commit()
    command_buffer.waitUntilCompleted()
    
    return output_texture
}


/// Per-pixel absolute difference between two equally sized float textures
/// (e.g. the cropped reference texture and a warped comparison texture).
/// The comparison texture can be brightness-matched to the reference via gain and offset.
func abs_difference(_ ref_texture: MTLTexture, _ comp_texture: MTLTexture, gain: Float = 1.0, offset: Float = 0.0) -> MTLTexture {
    
    precondition(ref_texture.width == comp_texture.width && ref_texture.height == comp_texture.height)
    
    let output_descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
                                                                     width: ref_texture.width,
                                                                     height: ref_texture.height,
                                                                     mipmapped: false)
    output_descriptor.usage = [.shaderRead, .shaderWrite]
    output_descriptor.storageMode = .private
    let output_texture = device.makeTexture(descriptor: output_descriptor)!
    output_texture.label = "Abs Difference"
    
    let command_buffer = command_queue.makeCommandBuffer()!
    command_buffer.label = "Abs Difference"
    let command_encoder = command_buffer.makeComputeCommandEncoder()!
    command_encoder.label = command_buffer.label
    command_encoder.setComputePipelineState(abs_difference_state)
    let threads_per_grid = MTLSize(width: ref_texture.width, height: ref_texture.height, depth: 1)
    let threads_per_thread_group = get_threads_per_thread_group(abs_difference_state, threads_per_grid)
    command_encoder.setTexture(ref_texture, index: 0)
    command_encoder.setTexture(comp_texture, index: 1)
    command_encoder.setTexture(output_texture, index: 2)
    command_encoder.setBytes([Float32(gain)], length: MemoryLayout<Float32>.stride, index: 0)
    command_encoder.setBytes([Float32(offset)], length: MemoryLayout<Float32>.stride, index: 1)
    command_encoder.dispatchThreads(threads_per_grid, threadsPerThreadgroup: threads_per_thread_group)
    command_encoder.endEncoding()
    command_buffer.commit()
    
    return output_texture
}


/// Read a float texture back to the CPU as mean-pooled values (pool size divides both dimensions).
func pooled_values(_ texture: MTLTexture, preferred_pool: Int) -> (values: [Float], pool: Int) {
    
    var pool = 1
    for candidate in stride(from: preferred_pool, through: 1, by: -1) {
        if texture.width % candidate == 0 && texture.height % candidate == 0 {
            pool = candidate
            break
        }
    }
    
    let pooled = avg_pool(texture, pool, 0.0, false, [-1.0, -1.0, -1.0])
    let buffer = blit_texture_to_shared_buffer(pooled, bytes_per_pixel: 2)
    
    let count = pooled.width * pooled.height
    let pointer = buffer.contents().bindMemory(to: UInt16.self, capacity: count)
    
    var values = [Float](repeating: 0.0, count: count)
    for i in 0..<count {
        let value = half_to_float(pointer[i])
        values[i] = value.isFinite ? value : 0.0
    }
    return (values, pool)
}


/// Mean and maximum pixel value of a float texture, computed on a pooled (downscaled) version to
/// keep the CPU readback cheap.
func texture_stats(_ texture: MTLTexture, preferred_pool: Int = 4) -> (mean: Float, max: Float) {
    
    let (values, _) = pooled_values(texture, preferred_pool: preferred_pool)
    
    var sum = 0.0
    var maximum: Float = 0
    for value in values {
        sum += Double(value)
        maximum = max(maximum, value)
    }
    return (mean: Float(sum / Double(values.count)), max: maximum)
}


/// Estimate a brightness match (comp_matched = gain * comp + offset ≈ ref) between two equally
/// sized arrays of (pooled) pixel values by linear regression: ref = gain * comp + offset.
/// This removes residual exposure differences (e.g. from imperfect metadata equalization) so that
/// difference images show motion and occlusion instead of a brightness ramp. Returns (1, 0) for
/// degenerate inputs.
func brightness_match_values(_ ref_values: [Float], _ comp_values: [Float]) -> (gain: Float, offset: Float) {
    
    precondition(ref_values.count == comp_values.count)
    
    var n = 0.0
    var sum_x = 0.0, sum_y = 0.0
    var sum_xx = 0.0, sum_xy = 0.0
    for i in 0..<ref_values.count {
        let x = Double(comp_values[i])
        let y = Double(ref_values[i])
        n += 1.0
        sum_x += x; sum_y += y
        sum_xx += x * x; sum_xy += x * y
    }
    
    let denominator = n * sum_xx - sum_x * sum_x
    guard denominator > 1e-9 else {
        return (gain: 1.0, offset: 0.0)  // flat comparison texture, nothing to match
    }
    let gain = Float((n * sum_xy - sum_x * sum_y) / denominator)
    let offset = Float((sum_y - Double(gain) * sum_x) / n)
    
    // guard against pathological fits (e.g. mostly-flat frames)
    guard gain.isFinite && offset.isFinite && gain > 0.2 && gain < 5.0 else {
        return (gain: 1.0, offset: 0.0)
    }
    return (gain: gain, offset: offset)
}


/// Estimate a brightness match between two equally sized textures by linear regression on
/// mean-pooled pixels (see brightness_match_values).
func brightness_match(_ ref_texture: MTLTexture, _ comp_texture: MTLTexture, preferred_pool: Int = 4) -> (gain: Float, offset: Float) {
    
    precondition(ref_texture.width == comp_texture.width && ref_texture.height == comp_texture.height)
    
    let (ref_values, ref_pool) = pooled_values(ref_texture, preferred_pool: preferred_pool)
    let (comp_values, comp_pool) = pooled_values(comp_texture, preferred_pool: preferred_pool)
    precondition(ref_pool == comp_pool && ref_values.count == comp_values.count)
    
    return brightness_match_values(ref_values, comp_values)
}


/// Convert a half-precision bit pattern to Float (kept dependency-free for older deployment targets).
func half_to_float(_ half_bits: UInt16) -> Float {
    
    let sign = Float((half_bits >> 15) & 1) * -2.0 + 1.0
    let exponent = Int((half_bits >> 10) & 0x1F)
    let mantissa = Int(half_bits & 0x3FF)
    
    if exponent == 0 {
        return sign * Float(mantissa) * powf(2.0, -24.0)  // subnormal
    } else if exponent == 0x1F {
        return mantissa == 0 ? sign * Float.infinity : Float.nan
    } else {
        return sign * Float(mantissa | 0x400) * powf(2.0, Float(exponent) - 25.0)
    }
}


/// Tonemap a single-channel float texture to 8-bit and wrap it in a bitmap that can be saved as
/// PNG. If `pool` > 1, the texture is first averaged in blocks of `pool` x `pool` pixels.
func render_gray_bitmap(_ texture: MTLTexture, white_point: Float, gain: Float, pool: Int = 1) -> NSBitmapImageRep {
    
    let source = (pool > 1) ? avg_pool(texture, pool, 0.0, false, [-1.0, -1.0, -1.0]) : texture
    
    let output_descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                     width: source.width,
                                                                     height: source.height,
                                                                     mipmapped: false)
    output_descriptor.usage = [.shaderRead, .shaderWrite]
    output_descriptor.storageMode = .shared
    let output_texture = device.makeTexture(descriptor: output_descriptor)!
    output_texture.label = "Gray preview"
    
    let command_buffer = command_queue.makeCommandBuffer()!
    command_buffer.label = "Gray to RGBA8"
    let command_encoder = command_buffer.makeComputeCommandEncoder()!
    command_encoder.label = command_buffer.label
    command_encoder.setComputePipelineState(gray_to_rgba8_state)
    let threads_per_grid = MTLSize(width: output_texture.width, height: output_texture.height, depth: 1)
    let threads_per_thread_group = get_threads_per_thread_group(gray_to_rgba8_state, threads_per_grid)
    command_encoder.setTexture(source, index: 0)
    command_encoder.setTexture(output_texture, index: 1)
    command_encoder.setBytes([Float32(white_point)], length: MemoryLayout<Float32>.stride, index: 0)
    command_encoder.setBytes([Float32(gain)], length: MemoryLayout<Float32>.stride, index: 1)
    command_encoder.dispatchThreads(threads_per_grid, threadsPerThreadgroup: threads_per_thread_group)
    command_encoder.endEncoding()
    command_buffer.commit()
    command_buffer.waitUntilCompleted()
    
    return bitmap_from_rgba8_texture(output_texture)
}


/// Render an alignment texture to a bitmap using the given color mode, scale (level-0 pixels) and
/// anchor offset (level-0 pixels, see render_alignment_texture).
func render_alignment_bitmap(_ alignment: MTLTexture, color_mode: AlignmentColorMode, scale: Int, block_size: Int = 8, offset: [Float] = [0.0, 0.0]) -> NSBitmapImageRep {
    
    return bitmap_from_rgba8_texture(render_alignment_texture(alignment, color_mode: color_mode, scale: scale, block_size: block_size, offset: offset))
}


/// Read an rgba8Unorm texture with shared storage back from the GPU into an NSBitmapImageRep.
func bitmap_from_rgba8_texture(_ texture: MTLTexture) -> NSBitmapImageRep {
    
    precondition(texture.pixelFormat == .rgba8Unorm && texture.storageMode == .shared)
    
    let bytes_per_row = texture.width * 4
    var pixels = [UInt8](repeating: 0, count: bytes_per_row * texture.height)
    texture.getBytes(&pixels, bytesPerRow: bytes_per_row,
                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                     mipmapLevel: 0)
    
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: texture.width,
                                  pixelsHigh: texture.height,
                                  bitsPerSample: 8,
                                  samplesPerPixel: 4,
                                  hasAlpha: true,
                                  isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: bytes_per_row,
                                  bitsPerPixel: 32)!
    memcpy(bitmap.bitmapData!, &pixels, bytes_per_row * texture.height)
    
    return bitmap
}


/// Encode a bitmap as PNG data.
func png_data(_ bitmap: NSBitmapImageRep) -> Data {
    
    return bitmap.representation(using: .png, properties: [:])!
}


/// Save a bitmap as a PNG file.
func save_png(_ bitmap: NSBitmapImageRep, _ url: URL) throws {
    
    try png_data(bitmap).write(to: url)
}


/// Box-average a flat float array (row-major) to roughly `target_long_side` samples on the long
/// side, keeping the aspect ratio. Used to build small thumbnails from pooled pixel values.
func downsample_values(_ values: [Float], width: Int, height: Int, target_long_side: Int = 48) -> (values: [Float], width: Int, height: Int) {
    
    precondition(values.count == width * height)
    var target_width = target_long_side
    var target_height = target_long_side
    if width >= height {
        target_height = max(height * target_long_side / width, 1)
    } else {
        target_width = max(width * target_long_side / height, 1)
    }
    
    var output = [Float](repeating: 0.0, count: target_width * target_height)
    for y in 0..<target_height {
        let y0 = y * height / target_height
        let y1 = max((y + 1) * height / target_height, y0 + 1)
        for x in 0..<target_width {
            let x0 = x * width / target_width
            let x1 = max((x + 1) * width / target_width, x0 + 1)
            var sum = 0.0
            for yy in y0..<y1 {
                let row = yy * width
                for xx in x0..<x1 {
                    sum += Double(values[row + xx])
                }
            }
            output[y * target_width + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
        }
    }
    return (output, target_width, target_height)
}


/// Tonemap flat float values to a grayscale 8-bit bitmap (CPU counterpart of gray_to_rgba8).
func gray_bitmap_from_values(_ values: [Float], width: Int, height: Int, white_point: Float) -> NSBitmapImageRep {
    
    let bytes_per_row = width * 4
    var pixels = [UInt8](repeating: 0, count: bytes_per_row * height)
    for i in 0..<values.count {
        let u = min(max(values[i] / max(white_point, 1e-9), 0.0), 1.0)
        let byte = UInt8(u * 255.0)
        pixels[4 * i] = byte
        pixels[4 * i + 1] = byte
        pixels[4 * i + 2] = byte
        pixels[4 * i + 3] = 255
    }
    
    return NSBitmapImageRep(bitmapDataPlanes: nil,
                            pixelsWide: width,
                            pixelsHigh: height,
                            bitsPerSample: 8,
                            samplesPerPixel: 4,
                            hasAlpha: true,
                            isPlanar: false,
                            colorSpaceName: .deviceRGB,
                            bytesPerRow: bytes_per_row,
                            bitsPerPixel: 32)!
}
