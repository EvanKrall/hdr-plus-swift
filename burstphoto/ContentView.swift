import SwiftUI


enum AppState {
    case main, processing, image_saved
}

// short names of the exposure control and output bit depth settings (as used by perform_denoising)
let exposure_control_short_names = [
    " Off"                       : "Off",
    " Linear (full bit range)"   : "LinearFullRange",
    " Linear (relative +1 EV)"   : "Linear1EV",
    " Non-linear (target ±0 EV)" : "Curve0EV",
    " Non-linear (target +1 EV)" : "Curve1EV",
]
let output_bit_depth_short_names = [
    "Native"          : "Native",
    "Scale to 16 bit" : "16Bit",
]
/// Open the app's Preferences window (used by the settings buttons).
func open_preferences_window() {
    // Version specific function call, as this changed in macOS 13 (Ventura)
    // https://developer.apple.com/forums/thread/711940
    if #available(macOS 13, *) {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
      NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

/// Open dropped stack metadata files (.json, see burst/stack_record.swift) in the alignment
/// inspector: the stack's frames are loaded with the previously rejected/deselected ones
/// unchecked, so the selection can be reviewed and the stack re-merged (using the current
/// settings from the Preferences window). Call on a background thread.
func open_stack_files(_ urls: [URL], settings: AppSettings, progress: ProcessingProgress, inspection: InspectionCoordinator, app_state: Binding<AppState>, my_alert: Binding<MyAlert>) {
    var records: [StackRecord] = []
    for url in urls {
        if let record = load_stack_record(url: url) { records.append(record) }
    }
    guard let record = records.first else {
        DispatchQueue.main.async {
            my_alert.wrappedValue = MyAlert(show: true, title: "Could not open stack file",
                                            message: "None of the dropped files is a valid Burst Photo stack file. Please only drop .json files that Burst Photo created next to a merged image.",
                                            dismiss_button: .cancel())
        }
        return
    }
    if records.count > 1 {
        print("note: only the first of \(records.count) dropped stack files is opened")
    }
    
    // the stack's initial frames, restricted to files that still exist; frames that were not
    // selected last time start unchecked in the inspector
    let fm = FileManager.default
    let initial_urls = record.initial_urls.filter { fm.fileExists(atPath: $0.path) }
    let selected_urls = Set(record.selected_urls)
    let excluded_urls = Set(initial_urls.filter { !selected_urls.contains($0) })
    guard initial_urls.count >= 2 else {
        DispatchQueue.main.async {
            my_alert.wrappedValue = MyAlert(show: true, title: "Images missing",
                                            message: "Too few images of the stack were found on disk. Please make sure the original RAW files are still at the location recorded in the stack file.",
                                            dismiss_button: .cancel())
        }
        return
    }
    
    DispatchQueue.main.async {
        progress.int = 0
        progress.includes_conversion = false
        progress.phase_total = progress_units_per_burst
        progress.status_line = ""
        app_state.wrappedValue = .processing
    }
    
    do {
        let session = try perform_alignment_inspection(image_urls: initial_urls, progress: progress, tile_size: settings.tile_size, search_distance: settings.search_distance, tmp_dir: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
        DispatchQueue.main.async {
            app_state.wrappedValue = .main
            inspection.show(session: session, initial_urls: initial_urls, initially_excluded_urls: excluded_urls)
        }
    } catch {
        show_processing_error(error, my_alert: my_alert, app_state: app_state)
    }
}

/// Human-readable message for errors thrown by perform_alignment_inspection / perform_denoising.
func processing_error_message(_ error: Error) -> (title: String, message: String) {
    switch error {
    case ImageIOError.load_error:
        return ("Unsupported format", "Image format not supported. Please only use unprocessed RAW or DNG images. Using RAW images requires Adobe DNG Converter to be installed on your Mac.")
    case ImageIOError.save_error:
        return ("Image could not be saved", "The processed image could not be saved for an unknown reason. Sorry.")
    case AlignmentError.less_than_two_images:
        return ("Burst required", "Please drag & drop at least 2 images.")
    case AlignmentError.inconsistent_extensions:
        return ("Inconsistent formats", "Please make sure that all images have the same format.")
    case AlignmentError.inconsistent_resolutions:
        return ("Inconsistent resolution", "Please make sure that all images have the same resolution.")
    case AlignmentError.missing_dng_converter:
        return ("Missing Adobe DNG Converter", "Only DNG files are supported natively. If you wish to use other RAW formats, please download and install Adobe DNG Converter. Burst Photo will then be able to process most RAW formats automatically.")
    case AlignmentError.conversion_failed:
        return ("Conversion failed", "Image format not supported. Please only use unprocessed RAW or DNG images.")
    case AlignmentError.non_bayer_exposure_bracketing:
        return ("Unsupported exposure bracketing", "Exposure bracketing is not supported for your camera. Please only use images with uniform exposure.")
    case AlignmentError.no_capture_timestamps:
        return ("Capture time unavailable", "Automatic burst detection groups images by the capture time stored in their EXIF metadata, but no readable capture time was found in any of the dropped images.")
    case AlignmentError.no_bursts_found:
        return ("No bursts found", "Automatic burst detection groups images that were captured at most 1 second apart, but no such sequences were found among the dropped images.")
    default:
        return ("Unknown error", "Something went wrong. Sorry.")
    }
}

/// Clamp all persisted settings to valid values (called when a drop starts).
func validate_settings(_ settings: AppSettings) {
    // check input parameter tile size
    if settings.tile_size != "Small" && settings.tile_size != "Medium" && settings.tile_size != "Large" {
       settings.tile_size = "Medium"
    }
    
    // check input parameter search distance
    if settings.search_distance != "Small" && settings.search_distance != "Medium" && settings.search_distance != "Large" {
        settings.search_distance = "Medium"
    }
    
    // check input parameter merging algorithm
    if settings.merging_algorithm != "Fast" && settings.merging_algorithm != "Higher quality" {
        settings.merging_algorithm = "Fast"
    }
    
    // check input parameter exposure control
    if settings.exposure_control != " Off" && settings.exposure_control != " Linear (full bit range)" && settings.exposure_control != " Linear (relative +1 EV)" && settings.exposure_control != " Non-linear (target ±0 EV)" && settings.exposure_control != " Non-linear (target +1 EV)" {
        settings.exposure_control = " Linear (full bit range)"
    }
    
    // check input parameter output bit depth
    if settings.output_bit_depth != "Native" && settings.output_bit_depth != "Scale to 16 bit" {
        settings.output_bit_depth = "Native"
    }
    
    // check input parameter noise reduction
    if settings.noise_reduction < 1 || settings.noise_reduction > 23 {
        settings.noise_reduction = 13
    }
}

/// Report a processing error through the alert state and return the GUI to the main screen.
func show_processing_error(_ error: Error, my_alert: Binding<MyAlert>, app_state: Binding<AppState>) {
    let message = processing_error_message(error)
    DispatchQueue.main.async {
        my_alert.wrappedValue = MyAlert(show: true, title: message.title, message: message.message, dismiss_button: .cancel())
        app_state.wrappedValue = .main
    }
}

struct MyAlert {
    var show: Bool = false
    var title: String?
    var message: String?
    var dismiss_button: Alert.Button?
}


struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var inspection: InspectionCoordinator
    @State private var app_state = AppState.main
    @State private var image_urls: [URL] = []
    @StateObject var progress = ProcessingProgress()
    @State var my_alert = MyAlert()
    @State private var out_urls: [URL] = []
    @State private var saved_summary: String? = nil
    @State private var saved_stacks: [StackRecord] = []
    @State var drop_active = false
    @State var auto_drop_active = false
    
    var body: some View {
        let drop_delegate = MyDropDelegate(settings: settings, app_state: $app_state, image_urls: $image_urls, progress: progress, active: $drop_active, my_alert: $my_alert, out_urls: $out_urls, saved_summary: $saved_summary, saved_stacks: $saved_stacks, inspection: inspection)
        let auto_drop_delegate = AutoBurstDropDelegate(settings: settings, app_state: $app_state, progress: progress, active: $auto_drop_active, my_alert: $my_alert, out_urls: $out_urls, saved_summary: $saved_summary, saved_stacks: $saved_stacks, inspection: inspection)
        
        Group {
            switch app_state {
            case .main:
                // two drop targets: the classic one (stacks everything dropped) and the
                // automatic one (detects bursts by capture time, rejects poor matches)
                MainView(regular_active: $drop_active, auto_active: $auto_drop_active,
                         regular_delegate: drop_delegate, auto_delegate: auto_drop_delegate)
            case .processing:
                ProcessingView(progress: progress)
            case .image_saved:
                ImageSavedView(stacks: $saved_stacks, summary: $saved_summary, drop_active: $drop_active)
                    .onDrop(of: ["public.file-url"], delegate: drop_delegate)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(drop_active ? Color.accentColor : Color.clear, lineWidth: 5).opacity(0.5))
                    .ignoresSafeArea()
            }
        }
        .alert(isPresented: $my_alert.show, content: {
            return Alert(
                title: Text(my_alert.title!),
                message: Text(my_alert.message!),
                dismissButton: my_alert.dismiss_button!
            )
        })
        .onReceive(progress.$show_nonbayer_hq_alert, perform: { val in
            if val {
                my_alert.title = "Higher quality not supported"
                my_alert.message = "You have selected the \"Higher quality\" merging algorithm in Preferences but your camera only supports the \"Fast\" algorithm. Press OK to use the \"Fast\" algorithm."
                my_alert.dismiss_button = .default(Text("OK"))
                my_alert.show = true
                settings.merging_algorithm = "Fast"
            }
        })
        .onReceive(progress.$show_nonbayer_exposure_alert, perform: { val in
            if val {
                my_alert.title = "Exposure control not supported"
                my_alert.message = "You have selected exposure control other than \"Off\" in Preferences, which is not supported for your camera. Press OK to disable exposure control."
                my_alert.dismiss_button = .default(Text("OK"))
                my_alert.show = true
                settings.exposure_control = " Off"
            }
        })
        .onReceive(progress.$show_nonbayer_bit_depth_alert, perform: { val in
            if val {
                my_alert.title = "16 bit output bit depth not supported"
                my_alert.message = "You have selected \"Scale to 16 bit\" as output bit depth in Preferences but your camera only supports the \"Native\" output bit depth. Press OK to use the \"Native\" output bit depth."
                my_alert.dismiss_button = .default(Text("OK"))
                my_alert.show = true
                settings.output_bit_depth = "Native"
            }
        })
        .onReceive(progress.$show_exposure_bit_depth_alert, perform: { val in
            if val {
                my_alert.title = "16 bit output bit depth not supported"
                my_alert.message = "You have selected the combination \"Scale to 16 bit\" as output bit depth and exposure control \"Off\" in Preferences, which is not supported. Press OK to use the \"Native\" output bit depth."
                my_alert.dismiss_button = .default(Text("OK"))
                my_alert.show = true
                settings.output_bit_depth = "Native"
            }
        })
        .onAppear {
            // bridge from the inspector window's merge button to the main window's state machine
            inspection.merge_handler = { initial, selected in self.run_merge(initial_urls: initial, selected_urls: selected) }
        }
        .frame(width: 360, height: 400)
    }
    
    /// Run the regular align+merge pipeline (triggered by the "Merge into image" button of the
    /// alignment inspector window). `initial_urls` are all frames of the inspected burst,
    /// `selected_urls` the ones still checked by the user.
    func run_merge(initial_urls: [URL], selected_urls: [URL]) {
        progress.int = 0
        progress.includes_conversion = false
        progress.phase_total = progress_units_per_burst
        progress.status_line = ""
        app_state = .processing
        DispatchQueue.global().async {
            do {
                let (out_url, record) = try perform_denoising(image_urls: selected_urls, initial_image_urls: initial_urls, progress: self.progress, merging_algorithm: self.settings.merging_algorithm, tile_size: self.settings.tile_size, search_distance: self.settings.search_distance, noise_reduction: self.settings.noise_reduction, exposure_control: exposure_control_short_names[self.settings.exposure_control] ?? "LinearFullRange", output_bit_depth: output_bit_depth_short_names[self.settings.output_bit_depth] ?? "Native", out_dir: NSHomeDirectory() + "/Pictures/Burst Photo/", tmp_dir: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
                DispatchQueue.main.async {
                    self.out_urls = [out_url]
                    self.saved_stacks = [record]
                    self.saved_summary = nil
                    self.app_state = .image_saved
                }
            } catch {
                show_processing_error(error, my_alert: self.$my_alert, app_state: self.$app_state)
            }
        }
    }
}


struct DropIcon: View {
    @Binding var drop_active: Bool
    
    var body: some View {
        Image(nsImage: NSImage(named: NSImage.Name("drop_icon")) ?? NSImage())
            .resizable()
            .renderingMode(.template)
            .foregroundColor(.primary)
            .opacity(drop_active ? 0.55 : 0.4)
            .frame(width: 164, height: 164)
    }
}


/// One of the two drop targets of the main screen: an icon, a short title and a description,
/// highlighted with an accent border while a drag hovers over it.
struct DropZone: View {
    /// SF Symbol name; nil uses the classic "drop_icon" app icon
    let system_image: String?
    let title: String
    let subtitle: String
    @Binding var active: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            if let name = system_image {
                Image(systemName: name)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundColor(.primary)
                    .opacity(active ? 0.55 : 0.4)
                    .frame(width: 56, height: 56)
            } else {
                Image(nsImage: NSImage(named: NSImage.Name("drop_icon")) ?? NSImage())
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(.primary)
                    .opacity(active ? 0.55 : 0.4)
                    .frame(width: 92, height: 92)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.85)
            Text(subtitle)
                .font(.system(size: 10))
                .opacity(0.6)
                .multilineTextAlignment(.center)
                .frame(height: 40)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.4), lineWidth: active ? 3 : 1))
    }
}


struct MainView: View {
    @Binding var regular_active: Bool
    @Binding var auto_active: Bool
    let regular_delegate: MyDropDelegate
    let auto_delegate: AutoBurstDropDelegate
    
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            
            Text("Drag & drop RAW images")
                .multilineTextAlignment(.center)
                .font(.system(size: 19, weight: .medium))
                .opacity(0.8)
                .frame(width: 220)
            
            Spacer()
            
            HStack(spacing: 12) {
                // classic target: stacks all dropped images into one merged image
                DropZone(system_image: nil,
                         title: "Stack a burst",
                         subtitle: "Merges all dropped images into one noise-reduced image",
                         active: $regular_active)
                    .onDrop(of: ["public.file-url"], delegate: regular_delegate)
                
                // automatic target: detects bursts by capture time and rejects poor matches
                DropZone(system_image: "square.stack.3d.up",
                         title: "Auto-detect bursts",
                         subtitle: "Splits a folder into bursts by capture time, drops frames that don't match",
                         active: $auto_active)
                    .onDrop(of: ["public.file-url"], delegate: auto_delegate)
            }
            .padding(.horizontal, 15)
            
            Spacer()
            
            Text("*.DNG, *.ARW, *.NEF, *.CR2…")
                .font(.system(size: 13, weight: .light))
                .italic()
                .opacity(0.8)
                .padding(3)
            
            HStack {
                SettingsButton().padding(15)
                Spacer()
                HelpButton().padding(15)
            }
        }
    }
}


/// The screen shown after processing: the result, the frames/settings summary of the produced
/// stack(s), and buttons to reveal the image(s) in Finder and to open the Preferences window.
/// Re-merging with different settings is done by dropping the stack's .json file back onto the
/// app (opens the alignment inspector) and adjusting the settings in Preferences.
struct ImageSavedView: View {
    @Binding var stacks: [StackRecord]
    @Binding var summary: String?
    @Binding var drop_active: Bool
    
    /// summary line below the title
    private var info_line: String {
        if let summary = summary, !summary.isEmpty { return summary }
        if stacks.count == 1, let stack = stacks.first {
            return "Merged \(stack.selected_files.count) of \(stack.initial_files.count) images · \(stack.output_url.lastPathComponent)"
        }
        if stacks.count > 1 { return "\(stacks.count) images saved" }
        return "Open the image using the button below or drag & drop a new burst."
    }
    
    private var output_urls_on_disk: [URL] {
        stacks.map { $0.output_url }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    
    var body: some View {
        VStack{
            Spacer()
            
            VStack{
                Text(stacks.count == 1 ? "Image saved" : "\(stacks.count) images saved")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 26, weight: .medium))
                    .opacity(0.8)
                
                Text(info_line)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12))
                    .opacity(0.8)
                    .frame(width: 300)
                    .padding(1)
                
                HStack {
                    Button(action: {NSWorkspace.shared.activateFileViewerSelecting(output_urls_on_disk)},
                           label: {Text("Show in Finder")})
                        .disabled(output_urls_on_disk.isEmpty)
                    Button(action: open_preferences_window,
                           label: {Text("Settings…")})
                }
            }
            
            Spacer()
            
            DropIcon(drop_active: $drop_active)
            
            Spacer()
            
            HStack {
                SettingsButton().padding(15)
                Spacer()
                HelpButton().padding(15)
            }
        }
    }
}


struct ProcessingView: View {
    @ObservedObject var progress: ProcessingProgress

    /// Phase text for the current progress value. Progress is reported in units of one burst
    /// (progress_units_per_burst); when several bursts are processed automatically, the phase is
    /// derived from the position within the current burst so that the text alternates correctly
    /// (converting → loading → processing → saving) for every burst.
    func progress_int_to_str(_ int: Int) -> String {
        
        // map unit boundaries onto themselves so that a finished burst reads "saving", not "loading"
        let within = int == 0 ? 0 : (int - 1) % progress_units_per_burst + 1
        
        if progress.includes_conversion && within < 10_000_000 {
            return "Converting images to DNG..."
        } else if within < 20_000_000 {
            return "Loading images..."
        } else if within < 100_000_000 {
            
            // use a very high number for the 100% mark to minimize any rounding errors
            let percent = round(Double(within - 20_000_000) / 800_000 * 10) / 10.0
                       
            return "Processing images (\(percent)%)..."
            
        } else {
            return "Saving processed image..."
        }
    }
    
    var body: some View {
        let label = (progress.status_line.isEmpty ? "" : progress.status_line + " ") + progress_int_to_str(progress.int)
        return ProgressView(label, value: Double(min(progress.int, progress.phase_total)), total: Double(progress.phase_total))
            .font(.system(size: 16, weight: .medium))
            .opacity(0.8)
            .padding(20)
        
    }
}


struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let tile_sizes = ["Small", "Medium", "Large"]
    let search_distances = ["Small", "Medium", "Large"]
    let merging_algorithms = ["Fast", "Higher quality"]
    let exposure_controls = [" Off", " Linear (full bit range)", " Linear (relative +1 EV)", " Non-linear (target ±0 EV)", " Non-linear (target +1 EV)"]
    let output_bit_depths = ["Native", "Scale to 16 bit"]
    
    @State private var user_changing_nr = false
    @State private var skip_haptic_feedback = false
     
    var body: some View {
        TabView {
            VStack(alignment: .leading) {
                
                HStack {
                    Text("Exposure control").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker(selection: settings.$exposure_control, label: EmptyView()) {
                        ForEach(exposure_controls, id: \.self) {
                            Text($0)
                        }
                    }.pickerStyle(MenuPickerStyle()).frame(width: 216)
                }.padding(.horizontal, 15).padding(.top, 20).padding(.bottom, 11)
                
                VStack(alignment: .leading) {
                    
                    (Text("Noise reduction: ") +
                     (settings.noise_reduction == 23
                      ? Text("max. ").foregroundColor(.accentColor) + Text("(simple average w/o alignment)")
                      : Text("\(Int(settings.noise_reduction))")
                     )).font(.system(size: 14, weight: .medium))
                        .opacity(user_changing_nr ? 0.75 : 1.0).padding(.top, 15)
                    
                    // the slider/stepper should provide haptic feedback when value changes
                    // but there's one exception: we don't provide feedback on the first click of the stepper,
                    // to avoid providing haptic feedback together with a system click
                    HStack {
                        Slider(value: settings.$noise_reduction, in: 1...23, step: 1,
                               onEditingChanged: { editing in user_changing_nr = editing }
                        ).onChange(of: settings.noise_reduction) { _ in
                            if !skip_haptic_feedback {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                            skip_haptic_feedback = false
                        }
                        Stepper("", value: settings.$noise_reduction, in: 1...23,
                                onEditingChanged: { editing in
                            user_changing_nr = editing
                            skip_haptic_feedback = editing // avoid proving haptic feedback on the first click
                        })
                    }
                    Text("  <      daylight scene      >         ...       <     night scene     >")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    Text("")
                    Text("Small values increase motion robustness and image sharpness")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Large values increase the strength of noise reduction")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }.padding(.horizontal, 15)
                Spacer()
                    .navigationTitle("Preferences")
            }.tabItem {Label("Exposure & Noise   ", image: "camera_icon").imageScale(.large)}
            
            VStack(alignment: .leading) {
                
                HStack {
                    Text("Tile size").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker(selection: settings.$tile_size, label: EmptyView()) {
                        ForEach(tile_sizes, id: \.self) {
                            Text($0)
                        }
                    }.pickerStyle(SegmentedPickerStyle()).frame(width: 216)
                }.padding(.horizontal, 15).padding(.top, 20).padding(.bottom, 11)
                
                HStack {
                    Text("Search distance").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker(selection: settings.$search_distance, label: EmptyView()) {
                        ForEach(search_distances, id: \.self) {
                            Text($0)
                        }
                    }.pickerStyle(SegmentedPickerStyle()).frame(width: 216)
                }.padding(.horizontal, 15).padding(.vertical, 11)
                
                HStack {
                    Text("Merging algorithm").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker(selection: settings.$merging_algorithm, label: EmptyView()) {
                        ForEach(merging_algorithms, id: \.self) {
                            Text($0)
                        }
                    }.pickerStyle(SegmentedPickerStyle()).frame(width: 216)
                }.padding(.horizontal, 15).padding(.vertical, 11)
                
                HStack {
                    Text("Output bit depth").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker(selection: settings.$output_bit_depth, label: EmptyView()) {
                        ForEach(output_bit_depths, id: \.self) {
                            Text($0)
                        }
                    }.pickerStyle(SegmentedPickerStyle()).frame(width: 216)
                }.padding(.horizontal, 15).padding(.vertical, 11)
                
                Toggle("Inspect alignment before merging", isOn: settings.$inspect_alignment)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                Text("Shows the alignment field and difference image of every frame in a separate window before merging.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 15)
                Spacer()
                    .navigationTitle("Preferences")
            }.tabItem {Label("Stacking & Output  ", image: "stack_icon").imageScale(.large)}
        }
        .frame(width: 390, height: 284)
    }
}

struct MyDropDelegate: DropDelegate {
    @ObservedObject var settings: AppSettings
    @Binding var app_state: AppState
    @Binding var image_urls: [URL]
    @ObservedObject var progress: ProcessingProgress
    @Binding var active: Bool
    @Binding var my_alert: MyAlert
    @Binding var out_urls: [URL]
    @Binding var saved_summary: String?
    @Binding var saved_stacks: [StackRecord]
    @ObservedObject var inspection: InspectionCoordinator
    
    
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: ["public.file-url"])
    }
    
    func dropEntered(info: DropInfo) {
        self.active = true
        if (app_state != .processing) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
    
    func dropExited(info: DropInfo) {
        self.active = false
        if (app_state != .processing) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        // https://swiftwithmajid.com/2020/04/01/drag-and-drop-in-swiftui/
        guard info.hasItemsConforming(to: ["public.file-url"]) else {
            return false
        }

        var all_file_urls: [URL] = []
        let items = info.itemProviders(for: ["public.file-url"])
        for item in items {
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    all_file_urls.append(url)
                }
            }
        }

        // clamp the settings to valid values
        validate_settings(settings)
        
        // set simplified value for parameter exposure control
        let exposure_control_short = exposure_control_short_names[settings.exposure_control] ?? "LinearFullRange"
        
        // set simplified value for output bit depth
        let output_bit_depth_short = output_bit_depth_short_names[settings.output_bit_depth] ?? "Native"
        
        DispatchQueue.global().async {
            // wait until all the urls are loaded
            // - this a a dirty hack to avoid any sync/async handling
            while all_file_urls.count < items.count {
                usleep(1000)
            }
            
            // dropped stack metadata files (.json) open the alignment inspector instead
            let json_urls = all_file_urls.filter { $0.pathExtension.lowercased() == "json" }
            if !json_urls.isEmpty {
                open_stack_files(json_urls, settings: settings, progress: progress, inspection: inspection, app_state: $app_state, my_alert: $my_alert)
                return
            }
            
            // if a directory was drag-and-dropped, convert it to a list of urls
            image_urls = optionally_convert_dir_to_urls(all_file_urls)
            
            // sort the urls alphabetically
            image_urls.sort(by: {$0.path < $1.path})
            
            // sync GUI
            DispatchQueue.main.async {
                progress.int = 0
                progress.includes_conversion = false
                progress.phase_total = progress_units_per_burst
                progress.status_line = ""
                app_state = .processing
            }
            
            do {               
                if settings.inspect_alignment {
                    // alignment inspection: visualize the alignment fields and difference images
                    // of every frame against the reference frame before merging
                    let session = try perform_alignment_inspection(image_urls: image_urls, progress: progress, tile_size: settings.tile_size, search_distance: settings.search_distance, tmp_dir: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
                    DispatchQueue.main.async {
                        app_state = .main
                        inspection.show(session: session)
                    }
                } else {
                    // align and merge the burst
                    let (out_url, record) = try perform_denoising(image_urls: image_urls, progress: progress, merging_algorithm: settings.merging_algorithm, tile_size: settings.tile_size, search_distance: settings.search_distance, noise_reduction: settings.noise_reduction, exposure_control: exposure_control_short, output_bit_depth: output_bit_depth_short, out_dir: NSHomeDirectory() + "/Pictures/Burst Photo/", tmp_dir: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
                    
                    // inform the user about the saved image
                    DispatchQueue.main.async {
                        out_urls = [out_url]
                        saved_stacks = [record]
                        saved_summary = nil
                        app_state = .image_saved
                    }
                }

            } catch {
                show_processing_error(error, my_alert: $my_alert, app_state: $app_state)
            }
        }

        return true
    }
}


/// Drop target of the automatic burst pipeline (burst/autoburst.swift): accepts a directory (or a
/// pile) of RAW files, detects the bursts inside it by EXIF capture time, rejects frames that
/// match the reference poorly and merges each remaining burst into its own image.
struct AutoBurstDropDelegate: DropDelegate {
    @ObservedObject var settings: AppSettings
    @Binding var app_state: AppState
    @ObservedObject var progress: ProcessingProgress
    @Binding var active: Bool
    @Binding var my_alert: MyAlert
    @Binding var out_urls: [URL]
    @Binding var saved_summary: String?
    @Binding var saved_stacks: [StackRecord]
    @ObservedObject var inspection: InspectionCoordinator
    
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: ["public.file-url"])
    }
    
    func dropEntered(info: DropInfo) {
        self.active = true
        if (app_state != .processing) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
    
    func dropExited(info: DropInfo) {
        self.active = false
        if (app_state != .processing) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: ["public.file-url"]) else {
            return false
        }

        var all_file_urls: [URL] = []
        let items = info.itemProviders(for: ["public.file-url"])
        for item in items {
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    all_file_urls.append(url)
                }
            }
        }

        // clamp the settings to valid values (the same preferences drive the automatic merges)
        validate_settings(settings)
        
        // set simplified value for parameter exposure control
        let exposure_control_short = exposure_control_short_names[settings.exposure_control] ?? "LinearFullRange"
        
        // set simplified value for output bit depth
        let output_bit_depth_short = output_bit_depth_short_names[settings.output_bit_depth] ?? "Native"
        
        DispatchQueue.global().async {
            // wait until all the urls are loaded
            while all_file_urls.count < items.count {
                usleep(1000)
            }
            
            // dropped stack metadata files (.json) open the alignment inspector instead
            let json_urls = all_file_urls.filter { $0.pathExtension.lowercased() == "json" }
            if !json_urls.isEmpty {
                open_stack_files(json_urls, settings: settings, progress: progress, inspection: inspection, app_state: $app_state, my_alert: $my_alert)
                return
            }
            
            // sync GUI
            DispatchQueue.main.async {
                progress.int = 0
                progress.includes_conversion = false
                progress.phase_total = progress_units_per_burst
                progress.status_line = ""
                app_state = .processing
            }
            
            do {
                let result = try perform_auto_burst_processing(
                    all_urls: all_file_urls,
                    progress: progress,
                    merging_algorithm: settings.merging_algorithm,
                    tile_size: settings.tile_size,
                    search_distance: settings.search_distance,
                    noise_reduction: settings.noise_reduction,
                    exposure_control: exposure_control_short,
                    output_bit_depth: output_bit_depth_short,
                    out_dir: NSHomeDirectory() + "/Pictures/Burst Photo/",
                    tmp_dir: NSHomeDirectory() + "/Pictures/Burst Photo/.dngs/")
                
                DispatchQueue.main.async {
                    out_urls = result.merged_urls
                    saved_stacks = result.records
                    saved_summary = result.summary
                    app_state = .image_saved
                }
            } catch {
                show_processing_error(error, my_alert: $my_alert, app_state: $app_state)
            }
        }

        return true
    }
}


struct HelpButton: View {
    // https://blog.urtti.com/creating-a-macos-help-button-in-swiftui
    let action: () -> Void = {NSWorkspace.shared.open(URL(string: "https://burst.photo/help/")!)}

    var body: some View {
        Button(action: action, label: {
            ZStack {
                Circle()
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                    .background(Circle().foregroundColor(Color(NSColor.controlColor)))
                    .shadow(color: Color(NSColor.separatorColor).opacity(0.3), radius: 1)
                    .frame(width: 25, height: 25)
                Text("?").font(.system(size: 18, weight: .medium)).opacity(0.8)
            }
        })
        .buttonStyle(PlainButtonStyle())
    }
}


struct SettingsButton: View {
    // make the button open the app's settings / preferences window
    let action: () -> Void = open_preferences_window
    
    var body: some View {
        // https://stackoverflow.com/questions/65355696
        if #available(macOS 14, *) {
            SettingsLink(label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                        .background(Circle().foregroundColor(Color(NSColor.controlColor)))
                        .shadow(color: Color(NSColor.separatorColor).opacity(0.3), radius: 1)
                        .frame(width: 25, height: 25)
                    Image(systemName: "gearshape").resizable().frame(width: 15, height: 15).opacity(0.8)
                }
            })
            .buttonStyle(PlainButtonStyle())
        } else {
            Button(action: action, label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                        .background(Circle().foregroundColor(Color(NSColor.controlColor)))
                        .shadow(color: Color(NSColor.separatorColor).opacity(0.3), radius: 1)
                        .frame(width: 25, height: 25)
                    Image(systemName: "gearshape").resizable().frame(width: 15, height: 15).opacity(0.8)
                }
            })
            .buttonStyle(PlainButtonStyle())
        }
    }
}
