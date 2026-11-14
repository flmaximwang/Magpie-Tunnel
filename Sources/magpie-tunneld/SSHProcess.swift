import Foundation
import MagpieTunnelCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One spawned `ssh -N -L ...` child process. The child runs in its own
/// process group so a kill can take down everything it started (this is what
/// prevents the PPID=1 orphan-ssh problem the legacy bash daemon worked
/// around with pgrep).
final class SSHProcess {
    let pid: pid_t
    private var reaped = false
    private var cachedExitCode: Int32 = -1

    /// Hardened ssh argument list, byte-identical to the legacy bash daemon's.
    static func arguments(for target: TargetConfig) -> [String] {
        [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-L", "127.0.0.1:\(target.localPort):127.0.0.1:\(target.remotePort)",
            target.sshTarget,
        ]
    }

    /// Spawn ssh with stdout/stderr redirected to `logFD`, in a fresh process group.
    /// Returns nil when posix_spawn fails.
    init?(sshBinary: String, target: TargetConfig, logFD: Int32) {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var flags: Int16 = 0
        flags |= Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, flags)

        let args = [sshBinary] + SSHProcess.arguments(for: target)
        var pidValue: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        // posix_spawnp also resolves PATH when sshBinary is not absolute.
        let result = cArgs.withUnsafeBufferPointer { buffer in
            posix_spawnp(&pidValue, sshBinary, &fileActions, &attributes, buffer.baseAddress, environ)
        }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)

        guard result == 0 else { return nil }
        pid = pidValue
    }

    /// Blocking wait for the child; returns shell-style exit code
    /// (WEXITSTATUS, or 128+signal when killed). If the child was already
    /// reaped by `tryWait()`/`terminate()`, the cached code is returned.
    func wait() -> Int32 {
        if reaped { return cachedExitCode }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else { return -1 }
        reaped = true
        cachedExitCode = SSHProcess.exitCode(fromRawStatus: status)
        return cachedExitCode
    }

    /// Non-blocking probe: exit code if the child has exited, nil if still running.
    func tryWait() -> Int32? {
        if reaped { return cachedExitCode }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        reaped = true
        cachedExitCode = SSHProcess.exitCode(fromRawStatus: status)
        return cachedExitCode
    }

    var isRunning: Bool { !reaped && tryWait() == nil }

    /// Signal the child's whole process group.
    func signalGroup(_ signal: Int32) {
        kill(-pid, signal)
        kill(pid, signal)
    }

    /// TERMs the group, waits up to `grace`, then KILLs. Non-blocking-ish;
    /// the reaping happens later on the supervisor thread's `wait()`.
    func terminate(grace: TimeInterval = 1.0) {
        signalGroup(SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if tryWait() != nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        signalGroup(SIGKILL)
    }

    static func exitCode(fromRawStatus status: Int32) -> Int32 {
        if status & 0x7F == 0 { // WIFEXITED
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F) // signalled: shell convention
    }
}
