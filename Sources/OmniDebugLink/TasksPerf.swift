import Foundation
import Darwin

func registerPerfTasks() {
    OmniDebugLink.tasks.register(
        "get_perf",
        { _ in
            [
                "memory": memoryInfo(),
                "uptimeMs": OmniDebugLink.uptimeMs,
                "platform": OmniDebugLink.platform,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            ] as [String: Any]
        },
        description:
            "Process memory stats (resident size and phys footprint) from the kernel. "
            + "Apple platforms expose no frame-timing API to ordinary apps, so no "
            + "frame/fps numbers are reported.")
}

func memoryInfo() -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return ["error": "task_info failed: \(kr)"] }
    return [
        "rssBytes": Int(info.resident_size),
        "physFootprintBytes": Int(info.phys_footprint),
        "virtualBytes": Int(info.virtual_size),
    ]
}
