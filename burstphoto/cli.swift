import Foundation
import MetalPerformanceShaders

// this is a command-line interface for Burst Photo, and is not part of the GUI application
// you can use this for development / automating jobs
//
// usage:
//   burstphoto-cli                             align+merge the bursts hardcoded below
//   burstphoto-cli inspect <burst_dir> [opts]  align all frames against the reference and export
//                                              alignment/difference visualizations as PNGs
//     opts:  --out <dir>                       output directory (default: <burst_dir>/alignment_inspection)
//            --tile Small|Medium|Large         tile size for the alignment (default: Medium)
//            --search Small|Medium|Large       search distance for the alignment (default: Medium)
//            --scale <px>                      manual color scale for the alignment field, in
//                                              pyramid-level-0 pixels (default: auto = max |shift|)
//   burstphoto-cli selftest                    run built-in verification tests of the alignment
//                                              inspection pipeline (no input files needed)

@main
struct MyProgram {
    static func main() throws {
        
        // initialize Adobe XMP SDK
        initialize_xmp_sdk()
        
        let arguments = CommandLine.arguments
        if arguments.count >= 2 && arguments[1] == "selftest" {
            let success = run_selftest()
            terminate_xmp_sdk()
            if !success { exit(1) }
            return
        }
        
        if arguments.count >= 2 && arguments[1] == "inspect" {
            guard arguments.count >= 3 else {
                print("usage: burstphoto-cli inspect <burst_dir> [--out <dir>] [--tile Small|Medium|Large] [--search Small|Medium|Large] [--scale <px>]")
                terminate_xmp_sdk()
                exit(1)
            }
            try run_inspection_cli(burst_dir: arguments[2], options: Array(arguments[3...]))
            terminate_xmp_sdk()
            return
        }
        
        try run_default_denoising()
        
        // terminate Adobe XMP SDK
        terminate_xmp_sdk()
    }
    
    
    /// The original CLI behavior: align+merge the bursts listed below.
    static func run_default_denoising() throws {
        
        // create output directory
        let out_dir = NSHomeDirectory() + "/Pictures/Burst Photo/"
        if !FileManager.default.fileExists(atPath: out_dir) {
            try FileManager.default.createDirectory(atPath: out_dir, withIntermediateDirectories: true, attributes: nil)
        }
        
        let tmp_dir = out_dir + ".dngs/"
        // If it exists, delete a previously leftover temporary directory
        var isDirectory : ObjCBool = true
        if FileManager.default.fileExists(atPath: tmp_dir, isDirectory: &isDirectory) {
            try FileManager.default.removeItem(atPath: tmp_dir)
        }
        try FileManager.default.createDirectory(atPath: tmp_dir, withIntermediateDirectories: true)
        
        // create a list of bursts to process
        let burst_dirs = [
                     
            "/Volumes/My Burst Folder/Burst 01/",
            //"/Volumes/My Burst Folder/Burst 02/",
            //"/Volumes/My Burst Folder/Burst 03/",
        ]
        
        // iterate over bursts
        for burst_dir in burst_dirs {
            
            // load image paths for the burst
            let fm = FileManager.default
            let burst_url = URL(fileURLWithPath: burst_dir)
            var image_urls = try fm.contentsOfDirectory(at: burst_url, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            image_urls.sort(by: {$0.path < $1.path})
            
            // ProcessingProgress is only useful for a GUI, but we have to instantiate one anyway
            let progress = ProcessingProgress()
            
            // options: value range from 1.0 to 23.0
            let noise_reduction = 13.0
            // options: "Fast" or "Higher quality"
            let merging_algorithm = "Fast"
            // options: "Small", "Medium" or "Large"
            let tile_size = "Medium"
            // options: "Small", "Medium" or "Large"
            let search_distance = "Medium"
            // options: "Off", "LinearFullRange", "Linear1EV", "Curve0EV" or "Curve1EV"
            let exposure_control = "LinearFullRange"
            // options: "Native" or "16Bit"
            let output_bit_depth = "Native"
            
            // align+merge
            let out_url = try perform_denoising(image_urls: image_urls, progress: progress, merging_algorithm: merging_algorithm, tile_size: tile_size, search_distance: search_distance, noise_reduction: noise_reduction, exposure_control: exposure_control, output_bit_depth: output_bit_depth, out_dir: out_dir, tmp_dir: tmp_dir)
           
            print("Image saved in:", out_url.relativePath)            
        }
        
        // Delete the temporary DNG directory
        try FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
    }
    
    
    /// Alignment inspection mode: align all frames of a burst against the reference frame and export
    /// the alignment field and difference images as PNG files.
    static func run_inspection_cli(burst_dir: String, options: [String]) throws {
        
        // parse options
        var out_dir_arg: String? = nil
        var tile_size = "Medium"
        var search_distance = "Medium"
        var manual_scale: Int? = nil
        var match_exposure = true
        var diff_gain: Float = 4.0
        var diff_scale: Float? = nil
        var i = 0
        while i < options.count {
            switch options[i] {
            case "--out":
                i += 1; out_dir_arg = options[i]
            case "--tile":
                i += 1; tile_size = options[i]
            case "--search":
                i += 1; search_distance = options[i]
            case "--scale":
                i += 1; manual_scale = Int(options[i])
            case "--raw-diff":
                match_exposure = false
            case "--diff-gain":
                i += 1; diff_gain = Float(options[i]) ?? 4.0
            case "--diff-scale":
                i += 1; diff_scale = Float(options[i])
            default:
                print("unknown option:", options[i])
                exit(1)
            }
            i += 1
        }
        guard tile_size_dict[tile_size] != nil else { print("invalid --tile value"); exit(1) }
        guard search_distance_dict[search_distance] != nil else { print("invalid --search value"); exit(1) }
        
        // load image paths for the burst (DNG preferred; RAW files are converted with Adobe DNG Converter)
        let fm = FileManager.default
        let burst_url = URL(fileURLWithPath: burst_dir)
        var image_urls = try fm.contentsOfDirectory(at: burst_url, includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        let raw_extensions = ["dng", "nef", "cr2", "cr3", "arw", "orf", "rw2", "raf"]
        image_urls = image_urls.filter{raw_extensions.contains($0.pathExtension.lowercased())}
        let dng_only = image_urls.filter{$0.pathExtension.lowercased() == "dng"}
        if !dng_only.isEmpty {
            image_urls = dng_only
        }
        image_urls.sort(by: {$0.path < $1.path})
        guard image_urls.count >= 2 else {
            print("error: need at least 2 .dng files in", burst_dir)
            exit(1)
        }
        print("Inspecting burst of", image_urls.count, "images (tile:", tile_size, ", search:", search_distance, ")")
        
        let out_dir = out_dir_arg ?? burst_url.appendingPathComponent("alignment_inspection").path
        try fm.createDirectory(atPath: out_dir, withIntermediateDirectories: true)
        let tmp_dir = out_dir + "/.dngs/"
        try fm.createDirectory(atPath: tmp_dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp_dir) }
        
        // run the alignment inspection
        let progress = ProcessingProgress()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let session = try perform_alignment_inspection(image_urls: image_urls, progress: progress, tile_size: tile_size, search_distance: search_distance, tmp_dir: tmp_dir)
        print("Time to align all images: ", Float(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000, "s")
        
        // export visualizations
        var report = "burst: \(burst_dir)\nreference: \(session.frames[session.ref_idx].url.lastPathComponent)\n"
        report += "shifts are in pyramid level-0 pixels; multiply by \(session.frames[0].downscale_factor) for sensor pixels\n"
        report += (match_exposure ? "difference images are brightness-matched to the reference (y = m*x + b); ΔEV = brightness of the frame relative to the reference\n"
                                  : "difference images are raw (--raw-diff)\n")
        
        // Pass 1: measure every frame's mean difference so that all difference PNGs can share ONE
        // render scale and stay comparable between frames. The median of the per-frame means is used
        // as the reference brightness so that outlier frames (huge motion) do not compress the rest.
        var diff_means: [Float] = []
        for frame in session.frames where !frame.is_reference {
            let diff_texture = session.difference_texture(for: frame.index, match_exposure: match_exposure)
            diff_means.append(texture_stats(diff_texture).mean)
        }
        let sorted_means = diff_means.sorted()
        let median_mean: Float = sorted_means.isEmpty ? 1.0 : (sorted_means.count % 2 == 1 ? sorted_means[sorted_means.count / 2] : 0.5 * (sorted_means[sorted_means.count / 2 - 1] + sorted_means[sorted_means.count / 2]))
        let shared_white_point: Float
        if let diff_scale = diff_scale {
            shared_white_point = max(diff_scale, 1e-9)
            report += String(format: "difference images share one render scale: white = %.0f (--diff-scale)\n\n", shared_white_point)
        } else {
            shared_white_point = max(diff_gain * median_mean, 1e-9)
            report += String(format: "difference images share one render scale: white = %.1f x median frame mean difference (%.1f) = %.0f (--diff-gain / --diff-scale to override);\nbright blobs = moving content\n\n", diff_gain, median_mean, shared_white_point)
        }
        
        // Shared alignment color scale for all frames: twice the median frame mean |shift|, capped
        // by the largest shift actually present in the burst (so no clipping, no all-gray renders).
        let mean_magnitudes = session.frames.compactMap{$0.stats?.mean_magnitude}.sorted()
        let median_magnitude = mean_magnitudes.isEmpty ? 1.0 : mean_magnitudes[mean_magnitudes.count / 2]
        let burst_max_abs_shift = session.frames.compactMap{$0.stats?.max_abs_shift}.max() ?? 1
        let alignment_scale = manual_scale ?? max(1, min(Int(median_magnitude * 2.0), max(burst_max_abs_shift, 1)))
        report += String(format: "alignment colors share one scale across frames: saturation at %d level-0 px (%d sensor px) = 2 x median frame mean |shift| (%.2f), capped by burst max %d (--scale to override)\n", alignment_scale, alignment_scale * session.frames[0].downscale_factor, median_magnitude, burst_max_abs_shift)
        
        for frame in session.frames {
            let name = String(format: "frame_%02d", frame.index) + "_" + frame.url.deletingPathExtension().lastPathComponent
            
            if frame.is_reference {
                let stats = texture_stats(session.ref_texture_cropped)
                let bitmap = render_gray_bitmap(session.ref_texture_cropped, white_point: max(stats.max, 1e-6), gain: 1.0, pool: 4)
                try save_png(bitmap, URL(fileURLWithPath: out_dir + "/reference_" + frame.url.deletingPathExtension().lastPathComponent + ".png"))
                report += "REF   \(frame.url.lastPathComponent)\n"
                print("reference:", frame.url.lastPathComponent)
                continue
            }
            
            let stats = frame.stats!
            let scale = alignment_scale
            
            // alignment field, both color modes
            try save_png(render_alignment_bitmap(frame.alignment_texture!, color_mode: .rgb_axes, scale: scale),
                         URL(fileURLWithPath: out_dir + "/" + name + "_alignment.png"))
            try save_png(render_alignment_bitmap(frame.alignment_texture!, color_mode: .hsv_flow, scale: scale),
                         URL(fileURLWithPath: out_dir + "/" + name + "_alignment_flow.png"))
            
            // difference image (brightness-matched unless --raw-diff; one shared render scale for all frames)
            let diff_texture = session.difference_texture(for: frame.index, match_exposure: match_exposure)
            let diff_stats = texture_stats(diff_texture)
            let diff_bitmap = render_gray_bitmap(diff_texture, white_point: shared_white_point, gain: 1.0, pool: 4)
            try save_png(diff_bitmap, URL(fileURLWithPath: out_dir + "/" + name + "_difference.png"))
            
            // warped comparison texture
            let aligned_texture = session.aligned_texture(for: frame.index)
            let aligned_stats = texture_stats(aligned_texture)
            let aligned_bitmap = render_gray_bitmap(aligned_texture, white_point: max(aligned_stats.max, 1e-6), gain: 1.0, pool: 4)
            try save_png(aligned_bitmap, URL(fileURLWithPath: out_dir + "/" + name + "_aligned.png"))
            
            // estimated residual brightness of this frame vs the reference (metadata equalization applied)
            let ev_string: String
            if match_exposure {
                let match = session.exposure_match(for: frame.index)
                let ev = log2(Double(match.gain))
                ev_string = String(format: "ΔEV %+.3f (gain %.4f, offset %+.5f)", -ev, match.gain, match.offset)
            } else {
                ev_string = "not estimated"
            }
            
            let line = "frame \(frame.index) \(frame.url.lastPathComponent): " +
                "dx [\(stats.min_dx)..\(stats.max_dx)] dy [\(stats.min_dy)..\(stats.max_dy)] " +
                "mean |shift| \(String(format: "%.2f", stats.mean_magnitude)) " +
                "mean diff \(String(format: "%.5f", diff_stats.mean)) " +
                ev_string
            report += line + "\n"
            print(line)
        }
        
        let report_url = URL(fileURLWithPath: out_dir + "/stats.txt")
        try report.write(to: report_url, atomically: true, encoding: .utf8)
        print("Results saved in:", out_dir)
    }
}
