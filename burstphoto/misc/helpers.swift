import Foundation
import MetalPerformanceShaders

/// Returns the amount of free disk space left on the system.
/// 
/// Based on https://stackoverflow.com/questions/36006713/how-to-get-the-total-disk-space-and-free-disk-space-using-attributesoffilesystem
func systemFreeDiskSpace() -> Double {
    let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)

    guard
        let lastPath = paths.last,
        let attributeDictionary = try? FileManager.default.attributesOfFileSystem(forPath: lastPath)
    else {
        return 0.0
    }

    if let size = attributeDictionary[.systemFreeSize] as? NSNumber {
        return Double(size.int64Value) / 1000 / 1000 / 1000
    } else {
        return 0.0
    }
}

func create_pipeline(with_function_name function_name: String, and_label label: String) -> MTLComputePipelineState {
    let _descriptor = MTLComputePipelineDescriptor()
    _descriptor.computeFunction = mfl.makeFunction(name: function_name)
    _descriptor.label = label
    return try! device.makeComputePipelineState(descriptor: _descriptor, options: []).0
}

/// Physical memory footprint of the current process in MB (resident + compressed + wired Metal
/// allocations), read from the kernel via task_info(). Used to monitor multi-burst runs.
func current_memory_footprint_mb() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        return Double(info.phys_footprint) / 1000 / 1000
    }
    return -1
}
