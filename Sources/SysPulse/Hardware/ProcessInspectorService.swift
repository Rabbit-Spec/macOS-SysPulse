import Foundation
import AppKit
import Darwin
import IOKit.pwr_mgt

// MARK: - 进程深度透视模型与实时内核采集服务

public struct ProcessMemberDetail: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var formattedMemory: String {
        ProcessInspectorService.formatBytes(memoryBytes)
    }
}

public struct ProcessInspectionSnapshot: Sendable, Equatable {
    public let appName: String
    public let rootPID: Int32
    public let bundleIdentifier: String?
    public let processCount: Int
    public let totalCPUPercent: Double
    public let totalMemoryBytes: UInt64
    public let ownerUser: String
    public let managedByDescription: String
    public let lineageChain: String

    public let threadCount: Int
    public let openFileCount: Int
    public let uptimeFormatted: String
    public let launchdTriggerReason: String
    public let launchdServiceName: String
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let listeningPortsSummary: String
    public let isListeningOnPublicInterface: Bool
    public let isPreventingSleep: Bool

    public let executablePath: String
    public let workingDirectory: String
    public let isProtectedSystemProcess: Bool
    public let members: [ProcessMemberDetail]

    public var formattedSummaryHeader: String {
        let countText = "\(processCount) 个进程"
        let cpuText = String(format: "CPU %.1f%%", totalCPUPercent)
        let memText = "MEM \(ProcessInspectorService.formatBytes(totalMemoryBytes))"
        return [countText, cpuText, memText, ownerUser, managedByDescription]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    public var formattedDiskIO: String {
        "读 \(ProcessInspectorService.formatBytes(diskReadBytes)) · 写 \(ProcessInspectorService.formatBytes(diskWriteBytes))"
    }

    public func exportDiagnosticText() -> String {
        var lines: [String] = []
        lines.append("进程深度分析: \(appName) (PID \(rootPID))")
        lines.append("摘要: \(formattedSummaryHeader)")
        lines.append("启动链路: \(lineageChain)")
        lines.append("线程数: \(threadCount) | 打开文件: \(openFileCount) | 已运行: \(uptimeFormatted)")
        lines.append("launchd 触发原因: \(launchdTriggerReason)")
        lines.append("launchd 服务: \(launchdServiceName)")
        lines.append("磁盘 I/O: \(formattedDiskIO)")
        lines.append("监听端口: \(listeningPortsSummary)\(isListeningOnPublicInterface ? " [警告: 正在监听公开网络接口]" : "")")
        if isPreventingSleep {
            lines.append("电源断言: 正在阻止系统休眠")
        }
        lines.append("可执行文件: \(executablePath)")
        lines.append("工作目录: \(workingDirectory)")
        if !members.isEmpty {
            lines.append("成员进程 (\(members.count)):")
            for m in members.prefix(20) {
                lines.append("  - \(m.name) (PID \(m.pid)): \(String(format: "%.1f%%", m.cpuPercent)) / \(m.formattedMemory)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ProcessInspectorService {
    private static let protectedProcessNames: Set<String> = [
        "launchd", "kernel_task", "WindowServer", "loginwindow",
        "opendirectoryd", "mds", "mds_stores", "UserEventAgent",
        "sysmond", "distnoted", "cfprefsd", "SysPulse"
    ]

    public static func isProtected(pid: Int32, name: String) -> Bool {
        if pid <= 1 || pid == getpid() {
            return true
        }
        return protectedProcessNames.contains(name)
    }

    public static func inspect(app: EnergyAppItem) async -> ProcessInspectionSnapshot {
        await Task.detached(priority: .userInitiated) {
            collectSync(app: app)
        }.value
    }

    public static func inspectCurrentSelf() -> ProcessInspectionSnapshot {
        let myPid = getpid()
        let item = EnergyAppItem(
            pid: myPid,
            name: "SysPulse",
            bundleIdentifier: Bundle.main.bundleIdentifier,
            cpuPercent: 0.0,
            energyImpact: 0.0,
            estimatedWatts: 0.1,
            memoryBytes: 0,
            memberCount: 1,
            memberPIDs: [myPid]
        )
        return collectSync(app: item)
    }

    private static func collectSync(app: EnergyAppItem) -> ProcessInspectionSnapshot {
        let pids = Array(Set(app.memberPIDs + [app.pid])).filter { $0 > 0 }
        let rootPID = app.pid

        var infoTB = mach_timebase_info_data_t()
        mach_timebase_info(&infoTB)

        var totalThreads = 0
        var totalOpenFiles = 0
        var totalDiskRead: UInt64 = 0
        var totalDiskWrite: UInt64 = 0
        var totalMemory: UInt64 = 0
        var earliestStartSec: Double? = nil
        var rootUID: uid_t = getuid()
        var rootCWD = ""
        var rootExecPath = ""

        var memberDetails: [ProcessMemberDetail] = []
        memberDetails.reserveCapacity(pids.count)

        let totalGroupMem = max(1, Int64(app.memoryBytes))
        for pid in pids {
            var bsd = proc_bsdinfo()
            let gotBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.stride))
                == Int32(MemoryLayout<proc_bsdinfo>.stride)
            if pid == rootPID && gotBSD {
                rootUID = bsd.pbi_uid
            }
            if gotBSD && bsd.pbi_start_tvsec > 0 {
                let startSec = Double(bsd.pbi_start_tvsec)
                if let existing = earliestStartSec {
                    earliestStartSec = min(existing, startSec)
                } else {
                    earliestStartSec = startSec
                }
            }

            var taskInfo = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.stride))
                == Int32(MemoryLayout<proc_taskinfo>.stride) {
                totalThreads += max(0, Int(taskInfo.pti_threadnum))
            }

            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if fdBytes > 0 {
                totalOpenFiles += Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
            }

            var rusage = rusage_info_v4()
            let ruRet = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ruPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, ruPtr)
                }
            }
            let memBytes: UInt64 = (ruRet == 0) ? rusage.ri_phys_footprint : 0
            if ruRet == 0 {
                totalDiskRead &+= rusage.ri_diskio_bytesread
                totalDiskWrite &+= rusage.ri_diskio_byteswritten
                totalMemory &+= memBytes
            }

            let procName: String = gotBSD ? extractComm(from: &bsd) : (pid == rootPID ? app.name : "PID \(pid)")
            let approxCPU: Double
            if pids.count == 1 {
                approxCPU = app.cpuPercent
            } else {
                let share = Double(memBytes) / Double(totalGroupMem)
                approxCPU = max(0.0, app.cpuPercent * min(1.0, share))
            }
            memberDetails.append(
                ProcessMemberDetail(
                    pid: pid,
                    name: procName,
                    cpuPercent: approxCPU,
                    memoryBytes: memBytes
                )
            )
        }

        memberDetails.sort { lhs, rhs in
            if lhs.memoryBytes != rhs.memoryBytes {
                return lhs.memoryBytes > rhs.memoryBytes
            }
            return lhs.cpuPercent > rhs.cpuPercent
        }

        if totalMemory == 0 {
            totalMemory = app.memoryBytes
        }

        rootExecPath = readExecPath(pid: rootPID)
        if rootExecPath.isEmpty,
           let running = NSRunningApplication(processIdentifier: rootPID),
           let url = running.executableURL ?? running.bundleURL {
            rootExecPath = url.path
        }

        rootCWD = readWorkingDirectory(pid: rootPID)
        if rootCWD.isEmpty {
            rootCWD = "/"
        }

        let ownerName = resolveUserName(uid: rootUID)
        let lineage = buildLineageChain(startingAt: rootPID, rootDisplayName: readExecNameOrComm(pid: rootPID, fallback: app.name))
        let uptimeText = formatRuntime(sinceEpochSec: earliestStartSec)
        let launchdMeta = inspectLaunchdProcInfo(pid: rootPID)
        let listenMeta = inspectListeningPorts(pids: pids)
        let preventingSleep = checkSleepAssertion(pids: Set(pids))

        let managedText = launchdMeta.isLaunchdManaged ? "由系统后台服务管理" : "用户会话进程"

        return ProcessInspectionSnapshot(
            appName: app.name,
            rootPID: rootPID,
            bundleIdentifier: app.bundleIdentifier,
            processCount: max(1, memberDetails.count),
            totalCPUPercent: app.cpuPercent,
            totalMemoryBytes: totalMemory,
            ownerUser: ownerName,
            managedByDescription: managedText,
            lineageChain: lineage,
            threadCount: max(1, totalThreads),
            openFileCount: max(0, totalOpenFiles),
            uptimeFormatted: uptimeText,
            launchdTriggerReason: launchdMeta.triggerReason,
            launchdServiceName: launchdMeta.serviceName,
            diskReadBytes: totalDiskRead,
            diskWriteBytes: totalDiskWrite,
            listeningPortsSummary: listenMeta.summary,
            isListeningOnPublicInterface: listenMeta.isPublic,
            isPreventingSleep: preventingSleep,
            executablePath: rootExecPath.isEmpty ? "未知路径" : rootExecPath,
            workingDirectory: rootCWD,
            isProtectedSystemProcess: isProtected(pid: rootPID, name: app.name),
            members: memberDetails
        )
    }

    private static func extractComm(from bsd: inout proc_bsdinfo) -> String {
        withUnsafePointer(to: &bsd.pbi_name) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(MAXCOMLEN)) { u8 in
                let buf = UnsafeBufferPointer(start: u8, count: Int(MAXCOMLEN))
                return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }

    private static func readExecNameOrComm(pid: Int32, fallback: String) -> String {
        let exec = readExecPath(pid: pid)
        if !exec.isEmpty {
            return URL(fileURLWithPath: exec).lastPathComponent
        }
        var bsd = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.stride))
            == Int32(MemoryLayout<proc_bsdinfo>.stride) {
            let comm = extractComm(from: &bsd)
            if !comm.isEmpty { return comm }
        }
        return fallback
    }

    private static func readExecPath(pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(len)), as: UTF8.self)
    }

    private static func readWorkingDirectory(pid: Int32) -> String {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else {
            return ""
        }
        return withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { raw in
            let prefix = raw.prefix { $0 != 0 }
            return String(decoding: prefix, as: UTF8.self)
        }
    }

    private static func resolveUserName(uid: uid_t) -> String {
        if let pw = getpwuid(uid), let namePtr = pw.pointee.pw_name {
            return String(cString: namePtr)
        }
        return NSUserName()
    }

    private static func buildLineageChain(startingAt pid: Int32, rootDisplayName: String) -> String {
        var chain: [(pid: Int32, name: String)] = [(pid, rootDisplayName)]
        var cursor = pid
        var guardSet: Set<Int32> = [pid]

        for _ in 0..<8 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(cursor, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.stride))
                == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
                break
            }
            let ppid = Int32(bsd.pbi_ppid)
            guard ppid >= 1, !guardSet.contains(ppid) else { break }
            guardSet.insert(ppid)

            var parentBSD = proc_bsdinfo()
            var parentName = ppid == 1 ? "launchd" : "PID \(ppid)"
            if proc_pidinfo(ppid, PROC_PIDTBSDINFO, 0, &parentBSD, Int32(MemoryLayout<proc_bsdinfo>.stride))
                == Int32(MemoryLayout<proc_bsdinfo>.stride) {
                let c = extractComm(from: &parentBSD)
                if !c.isEmpty { parentName = c }
            }
            chain.append((ppid, parentName))
            if ppid == 1 { break }
            cursor = ppid
        }

        return chain.reversed().map { "\($0.name) \($0.pid)" }.joined(separator: "  ›  ")
    }

    private static func formatRuntime(sinceEpochSec: Double?) -> String {
        guard let start = sinceEpochSec, start > 0 else { return "未知" }
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - start))
        let days = elapsed / 86400
        let hours = (elapsed % 86400) / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        if mins > 0 { return "\(mins)m" }
        return "\(secs)s"
    }

    private static func inspectLaunchdProcInfo(pid: Int32) -> (isLaunchdManaged: Bool, triggerReason: String, serviceName: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["procinfo", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil else {
            return (true, "系统会话托管", "--")
        }

        let sem = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + 1.0) == .timedOut {
            task.terminate()
            return (true, "系统会话托管", "--")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return (false, "手动或父进程启动", "--")
        }

        var serviceName = "--"
        var reason = "launch job demand"
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("service =") {
                serviceName = String(line.dropFirst("service =".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("program path =") && serviceName == "--" {
                continue
            } else if line.contains("spawn reason =") || line.contains("reason =") {
                if let eq = line.firstIndex(of: "=") {
                    let parsed = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !parsed.isEmpty { reason = parsed }
                }
            } else if serviceName == "--", line.hasPrefix("domain =") == false,
                      let firstToken = line.split(separator: " ").first,
                      firstToken.contains(".") && !firstToken.contains("/") {
                serviceName = String(firstToken).replacingOccurrences(of: "application.", with: "")
            }
        }
        serviceName = serviceName.replacingOccurrences(of: "application.", with: "")
        return (serviceName != "--", reason, serviceName)
    }

    private static func inspectListeningPorts(pids: [Int32]) -> (summary: String, isPublic: Bool) {
        guard !pids.isEmpty else { return ("无监听端口", false) }
        let limitedPids = pids.prefix(40).map(String.init).joined(separator: ",")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-a", "-p", limitedPids, "-iTCP", "-sTCP:LISTEN", "-F", "n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil else {
            return ("无监听端口", false)
        }
        let sem = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + 1.2) == .timedOut {
            task.terminate()
            return ("查询超时", false)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return ("无监听端口", false)
        }

        var uniqueAddresses: [String] = []
        var seen = Set<String>()
        var isPublic = false

        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let addr = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addr.isEmpty, seen.insert(addr).inserted else { continue }
            if addr.hasPrefix("*:") || addr.hasPrefix("0.0.0.0:") || addr.hasPrefix("[::]:") {
                isPublic = true
            }
            uniqueAddresses.append(addr)
        }

        if uniqueAddresses.isEmpty {
            return ("无监听端口", false)
        }
        if uniqueAddresses.count <= 2 {
            return (uniqueAddresses.joined(separator: ", "), isPublic)
        }
        let head = uniqueAddresses.prefix(2).joined(separator: ", ")
        return ("\(head) +\(uniqueAddresses.count - 2)", isPublic)
    }

    private static func checkSleepAssertion(pids: Set<Int32>) -> Bool {
        var dictRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictRef) == kIOReturnSuccess,
              let map = dictRef?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return false
        }
        for (pidNum, assertions) in map where pids.contains(pidNum.int32Value) {
            for item in assertions {
                let type = item["AssertType"] as? String ?? ""
                if type.contains("PreventUserIdleSystemSleep")
                    || type.contains("PreventSystemSleep")
                    || type.contains("NoIdleSleepAssertion") {
                    return true
                }
            }
        }
        return false
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1048576.0
        if mb >= 1024.0 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.0f KB", max(0.0, kb))
    }
}
