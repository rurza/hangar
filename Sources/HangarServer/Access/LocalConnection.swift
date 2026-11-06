import Darwin
import Foundation

/// Which macOS user opened a TCP connection that comes from this Mac itself. Tailscale's `whois` names a device, not
/// a process: on the server Mac every process that connects to the server's tailnet address resolves to the owner's
/// login, host-executor builds as `hangar` and anything else running there included. So a connection from this Mac
/// counts as the owner's only when a process of the server's own user holds its client end.
enum LocalConnection {
    /// True when a process of this process's user (other than this one) holds a TCP socket whose local port is
    /// `clientPort` and whose remote port is `serverPort`. Another user's processes are not even visible here
    /// (`proc_listpids` lists this user's only), so for them the answer is false.
    static func isOwnUsers(clientPort: Int, serverPort: Int) -> Bool {
        guard let client = UInt16(exactly: clientPort), let server = UInt16(exactly: serverPort), client != 0 else {
            return false
        }
        let me = getpid()
        for pid in pids(uid: getuid()) where pid != me {
            for fd in socketDescriptors(pid) {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                    info.psi.soi_kind == SOCKINFO_TCP
                else { continue }
                let ports = info.psi.soi_proto.pri_tcp.tcpsi_ini
                if port(ports.insi_lport) == client && port(ports.insi_fport) == server { return true }
            }
        }
        return false
    }

    /// A port as `in_sockinfo` stores it: network byte order in an `Int32`.
    private static func port(_ raw: Int32) -> UInt16 { UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)) }

    private static func pids(uid: uid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 32)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    private static func socketDescriptors(_ pid: pid_t) -> [Int32] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }.map(\.proc_fd)
    }
}
