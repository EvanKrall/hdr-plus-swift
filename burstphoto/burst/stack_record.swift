/**
 Stack metadata sidecars.

 Every image that Burst Photo produces is accompanied by a small JSON file (same name as the
 output DNG, but with a .json extension, in the same directory) describing how the image was
 made: which files were initially included, which frames were actually selected for the merge
 (e.g. after automatic rejection of poor matches), and all settings that affect the output.

 Dropping such a .json file onto the app re-opens the stack on the "image saved" screen, where
 the settings can be adjusted and the stack re-merged (see ContentView.swift).
 */
import Foundation

/// Schema version of the stack metadata format (bump on breaking changes).
let stack_record_schema_version = 1

/// Everything needed to reproduce a merged image later; persisted as JSON next to the output.
struct StackRecord: Codable {
    var schema_version: Int = stack_record_schema_version
    var app_version: String
    var created_at: Date
    /// path of the merged image this record describes
    var output_file: String
    /// all input files of the stack, before any frame was excluded/rejected
    var initial_files: [String]
    /// the frames that were actually merged
    var selected_files: [String]
    // the settings that affect the output (short names, as used by perform_denoising)
    var merging_algorithm: String
    var tile_size: String
    var search_distance: String
    var noise_reduction: Double
    var exposure_control: String
    var output_bit_depth: String
    
    var output_url: URL { URL(fileURLWithPath: output_file) }
    var initial_urls: [URL] { initial_files.map { URL(fileURLWithPath: $0) } }
    var selected_urls: [URL] { selected_files.map { URL(fileURLWithPath: $0) } }
    /// Path of the JSON sidecar storing this record (next to the output image, same base name).
    var sidecar_url: URL {
        output_url.deletingPathExtension().appendingPathExtension("json")
    }
}

/// Version of the running app, recorded in stack sidecars.
func app_version_string() -> String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleShortVersionString"] as? String)
        ?? (info?["CFBundleVersion"] as? String)
        ?? "unknown"
}

/// Write a stack record as a pretty-printed JSON file next to its output image.
func save_stack_record(_ record: StackRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)
    try data.write(to: record.sidecar_url, options: .atomic)
}

/// Read and validate a stack metadata file. Returns nil if the file is unreadable, uses an
/// unknown schema version, or contains fewer than 2 selected frames (nothing to merge).
func load_stack_record(url: URL) -> StackRecord? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(StackRecord.self, from: data),
          record.schema_version <= stack_record_schema_version,
          record.selected_files.count >= 2 else { return nil }
    return record
}
