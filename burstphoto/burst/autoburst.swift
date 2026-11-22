/**
 Automatic burst detection and stacking.

 Given a pile of RAW files — or directories of RAW files — the images are split into bursts by
 their EXIF capture time: successive frames of one burst are captured no more than 1 s apart.
 Every burst is aligned against its reference frame (the same alignment the inspection view
 performs); comparison frames whose alignment field varies too much inside the subject area —
 by default the region around the reference frame's selected autofocus point — are rejected,
 and the remaining frames are merged as usual. Bursts in which no comparison frame matches the
 reference well enough are skipped entirely.

 The score used for rejection is the alignment-field variation inside the subject area (see
 alignment_variation_in_roi() in inspect/inspect.swift), in pyramid level-0 pixels: the mean
 deviation of the per-tile shifts from the region's median shift. A low score means the frame
 maps rigidly onto the reference around the subject (handheld shake, focus breathing); a high
 score means the tiles could not agree on a mapping (subject motion, occlusion) and the frame
 is a poor match.
 */
import Foundation
import ImageIO

/// Maximum capture-time gap between successive frames of one burst (seconds).
let auto_burst_max_gap: TimeInterval = 1.0

/// Maximum alignment-variation score (pyramid level-0 pixels) a comparison frame may have inside
/// the subject area to still be merged; anything above is rejected as a poor match.
let auto_burst_max_alignment_score: Float = 10.0

/// File extensions accepted as RAW images (lower case).
let raw_extensions = ["dng", "nef", "cr2", "cr3", "arw", "orf", "rw2", "raf"]


/// Summary of one automatic burst-processing run.
struct AutoBurstResult {
    /// output DNGs, one per merged burst
    var merged_urls: [URL] = []
    /// bursts (groups of 2+ images captured within the gap limit) found among the input
    var n_bursts_detected = 0
    var n_bursts_merged = 0
    /// bursts skipped because no comparison frame matched the reference well enough
    var n_bursts_skipped_no_match = 0
    /// bursts that failed with an error (e.g. unsupported format)
    var n_bursts_failed = 0
    /// images that were alone in their time group (not stackable)
    var n_single_images = 0
    /// comparison frames rejected across all bursts because of a poor alignment score
    var n_frames_rejected = 0
    /// input files that carried no readable capture time (excluded from all bursts)
    var files_without_timestamp: [URL] = []
    /// the stack record written next to each merged image (see burst/stack_record.swift)
    var records: [StackRecord] = []
    
    /// One-line human-readable summary of the run.
    var summary: String {
        var parts = ["\(n_bursts_merged) of \(n_bursts_detected) burst\(n_bursts_detected == 1 ? "" : "s") merged"]
        if n_frames_rejected > 0 { parts.append("\(n_frames_rejected) frame\(n_frames_rejected == 1 ? "" : "s") rejected") }
        if n_bursts_skipped_no_match > 0 { parts.append("\(n_bursts_skipped_no_match) skipped (no match)") }
        if n_bursts_failed > 0 { parts.append("\(n_bursts_failed) failed") }
        if n_single_images > 0 { parts.append("\(n_single_images) single image\(n_single_images == 1 ? "" : "s")") }
        if !files_without_timestamp.isEmpty { parts.append("\(files_without_timestamp.count) without capture time") }
        return parts.joined(separator: " · ")
    }
}


/// Parse an EXIF date-time string ("yyyy:MM:dd HH:mm:ss"), optionally combined with a sub-second
/// string ("91" -> +0.91 s, "991" -> +0.991 s). Returns nil for malformed input.
func parse_exif_datetime(_ datetime: String, subsecond: String?) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    // EXIF timestamps carry no time zone; interpreting them in the local zone keeps the
    // intervals between images correct regardless of which zone is assumed
    formatter.timeZone = TimeZone.current
    guard var date = formatter.date(from: datetime) else { return nil }
    if let subsecond = subsecond,
       let digits = Double(subsecond), digits >= 0 {
        let seconds = digits >= 1 ? digits / pow(10, Double(subsecond.count)) : digits
        date.addTimeInterval(seconds)
    }
    return date
}


/// Capture time of an image file: DateTimeOriginal (1 s resolution) combined with
/// SubSecTimeOriginal when present, so that burst intervals shorter than 1 s can be resolved.
/// Falls back to DateTimeDigitized, then returns nil if no EXIF capture time exists.
func read_capture_timestamp(url: URL) -> Date? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
    guard let datetime = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
        ?? (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String) else { return nil }
    return parse_exif_datetime(datetime,
                               subsecond: (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)
                                   ?? (exif[kCGImagePropertyExifSubsecTime as String] as? String))
}


/// Read the capture time of every url in parallel. Files whose time cannot be read are simply
/// absent from the returned dictionary.
func read_capture_timestamps(urls: [URL]) -> [URL: Date] {
    var timestamps: [URL: Date] = [:]
    let lock = NSLock()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)
    for url in urls {
        group.enter()
        queue.async {
            if let date = read_capture_timestamp(url: url) {
                lock.lock()
                timestamps[url] = date
                lock.unlock()
            }
            group.leave()
        }
    }
    group.wait()
    return timestamps
}


/// Expand a list of dropped urls (files and/or directories) into a flat, alphabetically sorted
/// list of RAW file urls. Directories are replaced by their (non-recursive) non-hidden contents;
/// files that are not RAW images are dropped.
func collect_raw_urls(_ urls: [URL]) -> [URL] {
    let fm = FileManager.default
    var files: [URL] = []
    for url in urls {
        var is_dir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &is_dir), is_dir.boolValue {
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            files.append(contentsOf: contents)
        } else {
            files.append(url)
        }
    }
    return files
        .filter { raw_extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
}


/// Split timestamp-sorted files into bursts: files are ordered by capture time (then by path for
/// equal times), and a new burst starts whenever the gap between successive capture times exceeds
/// `max_gap`. Files without a timestamp are ignored (they cannot be placed in a sequence).
func split_into_bursts(urls: [URL], timestamps: [URL: Date], max_gap: TimeInterval) -> [[URL]] {
    let timed = urls.compactMap { url -> (URL, Date)? in timestamps[url].map { (url, $0) } }
    let sorted = timed.sorted { ($0.1, $0.0.path) < ($1.1, $1.0.path) }
    
    var bursts: [[URL]] = []
    var current: [(URL, Date)] = []
    for item in sorted {
        if let last = current.last, item.1.timeIntervalSince(last.1) > max_gap {
            bursts.append(current.map { $0.0 })
            current = []
        }
        current.append(item)
    }
    if !current.isEmpty { bursts.append(current.map { $0.0 }) }
    return bursts
}


/// Alignment-variation score of one comparison frame inside the region of interest (see
/// alignment_variation_in_roi). Nil if the frame has no alignment field (the reference).
func frame_alignment_score(session: InspectionSession, frame: InspectionFrame, roi: RoiRect) -> Float? {
    guard let alignment = frame.alignment_texture, let tile_info = frame.tile_info else { return nil }
    return alignment_variation_in_roi(texels: read_alignment_texels(alignment),
                                      alignment_width: alignment.width,
                                      alignment_height: alignment.height,
                                      tile_size: tile_info.tile_size,
                                      downscale_factor: frame.downscale_factor,
                                      roi: roi,
                                      frame_width: session.ref_texture_cropped.width,
                                      frame_height: session.ref_texture_cropped.height,
                                      pad_x: session.pad_x,
                                      pad_y: session.pad_y)
}


/// Main entry point of the automatic burst pipeline: detect bursts among the dropped urls,
/// reject poorly matching frames of each burst and merge the rest. `all_urls` may be a mix of
/// files and directories. The reference frame of each burst is always kept; comparison frames
/// whose alignment score exceeds `max_alignment_score` are rejected; a burst in which no
/// comparison frame survives is skipped. Errors of a single burst (e.g. unsupported format) are
/// recorded in the result and do not abort the remaining bursts.
func perform_auto_burst_processing(all_urls: [URL], progress: ProcessingProgress, merging_algorithm: String = "Fast", tile_size: String = "Medium", search_distance: String = "Medium", noise_reduction: Double = 13.0, exposure_control: String = "LinearFullRange", output_bit_depth: String = "Native", out_dir: String, tmp_dir: String, max_gap: TimeInterval = auto_burst_max_gap, max_alignment_score: Float = auto_burst_max_alignment_score) throws -> AutoBurstResult {
    
    var result = AutoBurstResult()
    
    // 1. flatten the input into raw file urls
    let raw_urls = collect_raw_urls(all_urls)
    if raw_urls.count < 2 { throw AlignmentError.less_than_two_images }
    
    // 2. read the capture time of every image
    print("Auto-detect bursts: reading capture times of \(raw_urls.count) images...")
    let timestamps = read_capture_timestamps(urls: raw_urls)
    result.files_without_timestamp = raw_urls.filter { timestamps[$0] == nil }
    if timestamps.count < 2 { throw AlignmentError.no_capture_timestamps }
    for url in result.files_without_timestamp {
        print("  no capture time found — excluded: " + url.lastPathComponent)
    }
    
    // 3. split into bursts by capture time
    let bursts = split_into_bursts(urls: raw_urls, timestamps: timestamps, max_gap: max_gap)
    let stackable = bursts.filter { $0.count >= 2 }
    result.n_bursts_detected = stackable.count
    result.n_single_images = bursts.count - stackable.count
    print("Detected \(stackable.count) burst(s) of 2+ images (\(result.n_single_images) single image(s)), using a maximum gap of \(max_gap) s")
    if stackable.isEmpty { throw AlignmentError.no_bursts_found }
    
    // progress: each burst contributes two units — one for the alignment pass (which decides the
    // frame selection) and one for the merge of the surviving frames
    let total_progress = progress_units_per_burst * stackable.count * 2
    DispatchQueue.main.async { progress.phase_total = total_progress }
    var processed_units = 0
    func advance_progress() {
        processed_units += 1
        let target = processed_units * progress_units_per_burst
        DispatchQueue.main.async { progress.int = max(progress.int, target) }
    }
    
    // 4. process the bursts one by one
    let n_bursts = stackable.count  // hoisted so the progress closures below capture only an Int
    for (burst_idx, burst_urls) in stackable.enumerated() {
        
        DispatchQueue.main.async { progress.status_line = "Burst \(burst_idx + 1) of \(n_bursts):" }
        print(String(format: "  memory footprint: %.0f MB", current_memory_footprint_mb()))
        // release the textures of the previous burst (the NSCache keeps textures for fast reuse,
        // but a long multi-burst run must not accumulate them)
        textureCache.removeAllObjects()
        
        DispatchQueue.main.async { progress.status_line = "Burst \(burst_idx + 1) of \(n_bursts):" }
        
        // prefer DNGs if the burst mixes formats (e.g. RAW files plus already-converted DNGs);
        // report the files this excludes so nothing is dropped silently
        let dngs = burst_urls.filter { $0.pathExtension.lowercased() == "dng" }
        let burst_files = dngs.isEmpty ? burst_urls : dngs
        if burst_files.count < burst_urls.count {
            print("  preferring \(dngs.count) DNG file(s); excluding: " + burst_urls.filter { $0.pathExtension.lowercased() != "dng" }.map { $0.lastPathComponent }.joined(separator: ", "))
        }
        
        print("Burst \(burst_idx + 1)/\(stackable.count): \(burst_files.count) images (\(burst_files.first!.lastPathComponent) … \(burst_files.last!.lastPathComponent))")
        
        do {
            // 4a. align every frame against the reference (identical setup to the merging)
            let session = try perform_alignment_inspection(image_urls: burst_files, progress: progress, tile_size: tile_size, search_distance: search_distance, tmp_dir: tmp_dir)
            advance_progress()
            
            // 4b. score every comparison frame inside the subject area (the reference frame's
            //     autofocus point, if the camera recorded one) and reject poor matches
            let roi = auto_burst_subject_roi(session: session)
            var kept_urls: [URL] = []
            var rejected_in_burst = 0
            for frame in session.frames {
                if frame.is_reference {
                    kept_urls.append(frame.url)
                    continue
                }
                let score = frame_alignment_score(session: session, frame: frame, roi: roi)
                if let score = score, score > max_alignment_score {
                    rejected_in_burst += 1
                    print("  rejected \(frame.url.lastPathComponent): alignment score \(String(format: "%.2f", score)) > \(Int(max_alignment_score))")
                } else {
                    if let score = score {
                        print("  kept      \(frame.url.lastPathComponent): alignment score \(String(format: "%.2f", score))")
                    } else {
                        print("  kept      \(frame.url.lastPathComponent): no alignment score available")
                    }
                    kept_urls.append(frame.url)
                }
            }
            result.n_frames_rejected += rejected_in_burst
            
            // 4c. skip bursts in which nothing matches the reference well
            guard kept_urls.count >= 2 else {
                result.n_bursts_skipped_no_match += 1
                print("  skipped: no comparison frame matches the reference well enough")
                advance_progress()
                continue
            }
            
            // 4d. merge the surviving frames (the merge picks its own reference among them)
            if rejected_in_burst > 0 {
                print("  merging \(kept_urls.count) of \(burst_files.count) images")
            }
            let (out_url, record) = try perform_denoising(image_urls: kept_urls, initial_image_urls: burst_files, progress: progress, merging_algorithm: merging_algorithm, tile_size: tile_size, search_distance: search_distance, noise_reduction: noise_reduction, exposure_control: exposure_control, output_bit_depth: output_bit_depth, out_dir: out_dir, tmp_dir: tmp_dir)
            result.merged_urls.append(out_url)
            result.records.append(record)
            result.n_bursts_merged += 1
            print("  saved: " + out_url.lastPathComponent)
        } catch AlignmentError.missing_dng_converter {
            // fatal for all bursts — the user must install the converter first
            throw AlignmentError.missing_dng_converter
        } catch {
            result.n_bursts_failed += 1
            print("  burst failed: \(error)")
        }
        advance_progress()
    }
    
    textureCache.removeAllObjects()
    print(String(format: "  memory footprint at end: %.0f MB", current_memory_footprint_mb()))
    
    DispatchQueue.main.async {
        progress.int = max(progress.int, total_progress - 1)
        progress.status_line = ""
    }
    print("Auto-detect bursts done: " + result.summary)
    
    return result
}
