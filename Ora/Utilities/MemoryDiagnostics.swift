import Foundation
import os

enum MemoryDiagnostics {
    struct Snapshot: Sendable {
        let footprintBytes: UInt64
        let residentBytes: UInt64
        let timestamp: Date

        var footprintString: String {
            Self.format(bytes: footprintBytes)
        }

        var residentString: String {
            Self.format(bytes: residentBytes)
        }

        private static func format(bytes: UInt64) -> String {
            let gigabytes = Double(bytes) / 1_073_741_824.0
            if gigabytes >= 1.0 {
                return String(format: "%.2fGB", gigabytes)
            }
            let megabytes = Double(bytes) / 1_048_576.0
            return String(format: "%.0fMB", megabytes)
        }
    }

    static func capture() -> Snapshot? {
        var footprint: UInt64 = 0
        var resident: UInt64 = 0

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vmInfo) / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &vmCount)
            }
        }

        if vmResult == KERN_SUCCESS {
            footprint = vmInfo.phys_footprint
        }

        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: basicInfo) / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basicInfo) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &basicCount)
            }
        }

        if basicResult == KERN_SUCCESS {
            resident = UInt64(basicInfo.resident_size)
        }

        guard vmResult == KERN_SUCCESS || basicResult == KERN_SUCCESS else {
            return nil
        }

        return Snapshot(footprintBytes: footprint, residentBytes: resident, timestamp: Date())
    }

    static func logSnapshot(label: String, logger: Logger) {
        guard let snapshot = capture() else {
            logger.warning("Memory snapshot failed (\(label, privacy: .public))")
            return
        }

        logger.info("Memory \(label, privacy: .public): footprint=\(snapshot.footprintString, privacy: .public) resident=\(snapshot.residentString, privacy: .public)")
    }
}
