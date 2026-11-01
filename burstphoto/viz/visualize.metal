#include <metal_stdlib>
#include "../misc/constants.h"
using namespace metal;


/**
 Render an alignment texture (rg16Sint, one texel per tile, shifts in pyramid-level-0 pixels)
 to a color image for visual inspection.

 One output pixel corresponds to one tile grid cell subdivided by 'block_size' in each dimension
 (block_size = 1 gives the blocky per-tile look, larger values give a smooth image).
 The shift of the four neighboring tile texels is bilinearly interpolated.

 'offset' (level-0 pixels) is subtracted from every tile shift BEFORE the color mapping, so that
 the tile under the offset becomes zero. Used by the inspection UI to visualize the alignment
 relative to a user-selected anchor point.

 Color mappings (color_mode):
 - 0 "RGB axes": R = 0.5 + 0.5*dx/scale, G = 0.5 + 0.5*dy/scale, B = 0
   -> zero shift is 50% gray, red encodes +x shifts, green encodes +y shifts
 - 1 "HSV flow": hue encodes the shift direction, brightness encodes the shift magnitude
   -> zero shift is black, like a classic optical-flow color wheel
 */
kernel void render_alignment_color(texture2d<int, access::read> alignment [[texture(0)]],
                                   texture2d<float, access::write> out_texture [[texture(1)]],
                                   constant int& color_mode [[buffer(0)]],
                                   constant float& scale [[buffer(1)]],
                                   constant int& block_size [[buffer(2)]],
                                   constant float2& offset [[buffer(3)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    
    int const n_tiles_x = alignment.get_width();
    int const n_tiles_y = alignment.get_height();
    
    // position in tile-grid coordinates; the +0.5/-0.5 centers output pixels within the tile block
    float const gx = (float(gid.x) + 0.5f) / float(block_size) - 0.5f;
    float const gy = (float(gid.y) + 0.5f) / float(block_size) - 0.5f;
    
    // bilinear interpolation between the four surrounding tile texels
    int const ix0 = clamp(int(floor(gx)), 0, n_tiles_x - 1);
    int const iy0 = clamp(int(floor(gy)), 0, n_tiles_y - 1);
    int const ix1 = clamp(ix0 + 1, 0, n_tiles_x - 1);
    int const iy1 = clamp(iy0 + 1, 0, n_tiles_y - 1);
    float const fx = clamp(gx - floor(gx), 0.0f, 1.0f);
    float const fy = clamp(gy - floor(gy), 0.0f, 1.0f);
    
    int2 const a00 = alignment.read(uint2(ix0, iy0)).xy;
    int2 const a10 = alignment.read(uint2(ix1, iy0)).xy;
    int2 const a01 = alignment.read(uint2(ix0, iy1)).xy;
    int2 const a11 = alignment.read(uint2(ix1, iy1)).xy;
    
    float const dx = mix(mix(float(a00.x), float(a10.x), fx), mix(float(a01.x), float(a11.x), fx), fy) - offset.x;
    float const dy = mix(mix(float(a00.y), float(a10.y), fx), mix(float(a01.y), float(a11.y), fx), fy) - offset.y;
    
    float3 rgb;
    if (color_mode == 0) {
        rgb = float3(clamp(0.5f + 0.5f * dx / scale, 0.0f, 1.0f),
                     clamp(0.5f + 0.5f * dy / scale, 0.0f, 1.0f),
                     0.0f);
    } else {
        // HSV flow: hue = shift direction, brightness = shift magnitude
        float const hue = (atan2(dy, dx) + PI) / (2.0f * PI);
        float const mag = clamp(length(float2(dx, dy)) / scale, 0.0f, 1.0f);
        
        // hue -> rgb (s = 1, v = mag)
        float const i = floor(hue * 6.0f);
        float const f = hue * 6.0f - i;
        if (i < 0.5f)              rgb = float3(1.0f, f, 0.0f);
        else if (i < 1.5f)         rgb = float3(1.0f - f, 1.0f, 0.0f);
        else if (i < 2.5f)         rgb = float3(0.0f, 1.0f, f);
        else if (i < 3.5f)         rgb = float3(0.0f, 1.0f - f, 1.0f);
        else if (i < 4.5f)         rgb = float3(f, 0.0f, 1.0f);
        else                       rgb = float3(1.0f, 0.0f, 1.0f - f);
        rgb *= mag;
    }
    
    out_texture.write(float4(rgb, 1.0f), gid);
}


/**
 Per-pixel absolute difference between two textures (e.g. the reference texture and a warped
 comparison texture). Both inputs must have the same size; the result keeps the full resolution
 and dynamic range so that it can be re-used for statistics and for rendering.

 The comparison texture can be brightness-matched to the reference first via gain and offset
 (out = abs(ref - (gain * comp + offset))); pass 1.0 and 0.0 for a plain difference.
 */
kernel void abs_difference(texture2d<float, access::read> ref_texture [[texture(0)]],
                           texture2d<float, access::read> comp_texture [[texture(1)]],
                           texture2d<float, access::write> out_texture [[texture(2)]],
                           constant float& gain [[buffer(0)]],
                           constant float& offset [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    
    out_texture.write(abs(ref_texture.read(gid).r - (gain * comp_texture.read(gid).r + offset)), gid);
}


/**
 Tonemap the SIGNED difference between two float textures to a color bitmap: pixels where the
 (brightness-matched) comparison texture is BRIGHTER than the reference are mapped to red, pixels
 where it is DARKER to blue, and equality to black. The difference is divided by 'white_point'
 before clamping.
 */
kernel void signed_difference_rgba8(texture2d<float, access::read> ref_texture [[texture(0)]],
                                    texture2d<float, access::read> comp_texture [[texture(1)]],
                                    texture2d<float, access::write> out_texture [[texture(2)]],
                                    constant float& gain [[buffer(0)]],
                                    constant float& offset [[buffer(1)]],
                                    constant float& white_point [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    
    float const difference = (gain * comp_texture.read(gid).r + offset) - ref_texture.read(gid).r;
    float const white = max(white_point, 1e-9f);
    float const red = clamp(difference / white, 0.0f, 1.0f);
    float const blue = clamp(-difference / white, 0.0f, 1.0f);
    out_texture.write(float4(red, 0.0f, blue, 1.0f), gid);
}


/**
 Tonemap a single-channel float texture to an 8-bit RGBA texture that can be read back on the CPU
 and displayed. The input value is divided by 'white_point' and multiplied by 'gain', then clamped.
 */
kernel void gray_to_rgba8(texture2d<float, access::read> in_texture [[texture(0)]],
                          texture2d<float, access::write> out_texture [[texture(1)]],
                          constant float& white_point [[buffer(0)]],
                          constant float& gain [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    
    float const value = in_texture.read(gid).r;
    float const u = clamp((value / max(white_point, 1e-9f)) * gain, 0.0f, 1.0f);
    out_texture.write(float4(u, u, u, 1.0f), gid);
}
