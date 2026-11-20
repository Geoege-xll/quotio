import Darwin
import Foundation

/// CPA 的监听端口只用于检查冲突。停止进程和验证管理接口时，归属始终来自本轮启动的 Process。
enum ProxyProcessOwnership {
    enum PortError: LocalizedError {
        case invalidPort
        case inUse(UInt16)
        case inspectionFailed(UInt16, Int32)

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "proxy.error.invalidPort".localizedStatic()
            case .inUse(let port):
                return String(format: "proxy.error.portInUse".localizedStatic(), Int(port))
            case .inspectionFailed(let port, let code):
                return String(
                    format: "proxy.error.portInspectionFailed".localizedStatic(),
                    Int(port), String(cString: strerror(code))
                )
            }
        }
    }

    static func requireAvailablePort(_ port: UInt16) throws {
        guard port != 0 else { throw PortError.invalidPort }
        // Darwin 允许使用 SO_REUSEADDR 的通配监听和具体地址监听并存。
        // 分别检查两者，避免漏掉外部通配/回环监听，也允许快速重启时复用 TIME_WAIT 端口。
        try checkBind(port: port, address: INADDR_ANY)
        try checkBind(port: port, address: INADDR_LOOPBACK.bigEndian)
    }

    /// 仅查询本轮 Process 的内核文件描述符。并存的外部监听可能抢占回环流量，因此也要检查另一种绑定。
    static func ownsLoopbackListener(_ process: Process, port: UInt16) -> Bool {
        guard process.isRunning else { return false }
        let pid = process.processIdentifier
        let bytesNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytesNeeded > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = Array(repeating: proc_fdinfo(), count: Int(bytesNeeded) / stride)
        let bytesRead = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytesRead > 0 else { return false }

        var ownsLoopback = false
        var ownsWildcard = false
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        for descriptor in descriptors.prefix(Int(bytesRead) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socketInfo = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, socketInfoSize) == socketInfoSize,
                  socketInfo.psi.soi_kind == SOCKINFO_TCP,
                  socketInfo.psi.soi_options & Int16(SO_REUSEPORT) == 0 else { continue }
            let tcp = socketInfo.psi.soi_proto.pri_tcp
            let address = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  address.insi_lport == Int32(port.bigEndian),
                  address.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
            switch address.insi_laddr.ina_46.i46a_addr4.s_addr {
            case INADDR_LOOPBACK.bigEndian: ownsLoopback = true
            case INADDR_ANY: ownsWildcard = true
            default: break
            }
        }

        guard process.isRunning else { return false }
        if ownsLoopback && ownsWildcard { return true }
        guard ownsLoopback || ownsWildcard else { return false }
        let otherAddress = ownsLoopback ? INADDR_ANY : INADDR_LOOPBACK.bigEndian
        return (try? checkBind(port: port, address: otherAddress)) != nil
    }

    private static func checkBind(port: UInt16, address: UInt32) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PortError.inspectionFailed(port, errno) }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, optionSize) == 0 else {
            throw PortError.inspectionFailed(port, errno)
        }

        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        endpoint.sin_addr.s_addr = address
        let result = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result != 0 else { return }
        let code = errno
        if code == EADDRINUSE { throw PortError.inUse(port) }
        throw PortError.inspectionFailed(port, code)
    }

    /// 停止操作由后台独立任务持有。先发送 TERM，随后只在同一个直接子进程仍存活时升级为 KILL。
    /// 使用单调时钟，并给强制终止留短暂的回收时间，避免退出时无限等待或者依赖固定重启延时。
    nonisolated static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let originalInfo = childInfo(pid)
        process.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning && clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(50))
        }
        guard process.isRunning, let originalInfo, let currentInfo = childInfo(pid),
              currentInfo.pbi_start_tvsec == originalInfo.pbi_start_tvsec,
              currentInfo.pbi_start_tvusec == originalInfo.pbi_start_tvusec,
              process.isRunning else { return }
        Darwin.kill(pid, SIGKILL)
        let reapDeadline = clock.now.advanced(by: .milliseconds(250))
        while process.isRunning && clock.now < reapDeadline {
            try? await clock.sleep(for: .milliseconds(25))
        }
    }

    private nonisolated static func childInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_ppid == UInt32(getpid()) else { return nil }
        return info
    }
}
