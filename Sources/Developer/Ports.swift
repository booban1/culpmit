import Foundation

// Dev servers listening on this Mac, read straight from the kernel and named by their processes

struct LocalServer: Hashable {
    let port: Int
    let name: String
}

private let devNames = ["node", "next", "python", "php", "ruby", "httpd", "mysqld", "mariadbd", "postgres", "redis", "java",
                        "deno", "bun", "docker", "com.docke", "vite", "nginx", "caddy", "hugo", "uvicorn", "gunicorn", "puma"]

// every TCP port in LISTEN state among this user's processes, with the process holding it; a few milliseconds, zero helpers
func listeners() -> [(port: Int, pid: pid_t)] {
    let count = Int(proc_listallpids(nil, 0))
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: count + 64)
    let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var out: [(port: Int, pid: pid_t)] = []
    for pid in pids.prefix(max(0, got)) where pid > 0 {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let used = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)) / MemoryLayout<proc_fdinfo>.stride
        for fd in fds.prefix(max(0, used)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            out.append((Int(UInt16(bigEndian: port)), pid))
        }
    }
    return out
}

func localServers(_ all: [(port: Int, pid: pid_t)] = listeners()) -> [LocalServer] {
    var found = Set<LocalServer>()
    for listener in all {
        let name = processName(listener.pid)
        guard devNames.contains(where: { name.lowercased().hasPrefix($0) }) else { continue }
        found.insert(LocalServer(port: listener.port, name: name))
    }
    return found.sorted { $0.port < $1.port }
}
