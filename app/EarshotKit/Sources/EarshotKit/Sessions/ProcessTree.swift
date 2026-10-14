import Darwin
import Foundation

/// A process's parents, for finding the app a session runs in: Claude Code's
/// parent is a shell, whose parent is Terminal, iTerm, Ghostty, an editor...
public enum ProcessTree {
    /// The parent process ID, or nil when the process is gone.
    public static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// `pid` and its parents, nearest first, stopping before launchd.
    /// `parent` is a seam for tests.
    public static func ancestors(of pid: Int32, limit: Int = 24,
                                 parent: (Int32) -> Int32? = ProcessTree.parent) -> [Int32] {
        var chain: [Int32] = []
        var p: Int32? = pid
        while let cur = p, cur > 1, chain.count < limit, !chain.contains(cur) {
            chain.append(cur)
            p = parent(cur)
        }
        return chain
    }
}
