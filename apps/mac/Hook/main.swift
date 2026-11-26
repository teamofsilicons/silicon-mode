import Foundation
#if canImport(Darwin)
import Darwin
#endif

// silicon-mode-hook <agent> [event]
//
// Called by agent hook systems (Claude Code `hooks`, Codex `notify`, …). Forwards the hook
// payload to the Silicon Mode app and relays its answer. If the app isn't running or anything
// goes wrong, exits 0 silently so the agent behaves exactly as without the hook.

setvbuf(stdout, nil, _IOFBF, 1 << 16)

let args = CommandLine.arguments
let agent = args.count > 1 ? args[1] : "unknown"
let event = args.count > 2 ? args[2] : nil

if agent == "--version" {
    print("silicon-mode-hook \(HookWire.version)")
    exit(0)
}

// Read all of stdin (agents send one JSON object).
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = String(decoding: input, as: UTF8.self)

var env: [String: String] = [:]
for k in HookWire.forwardedEnv { if let v = ProcessInfo.processInfo.environment[k] { env[k] = v } }

let req = HookWire.Request(agent: agent, event: event, payload: payload, ppid: getppid(),
                           cwd: FileManager.default.currentDirectoryPath, env: env)

func passThrough() -> Never { exit(0) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { passThrough() }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let path = HookWire.socketPath
guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { passThrough() }
withUnsafeMutablePointer(to: &addr.sun_path) { p in
    p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { c in
        _ = path.withCString { strncpy(c, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
    }
}
let len = socklen_t(MemoryLayout<sockaddr_un>.size)
let rc = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
}
guard rc == 0 else { close(fd); passThrough() }

// Don't die from SIGPIPE if the app goes away mid-write.
signal(SIGPIPE, SIG_IGN)
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

guard var line = try? JSONEncoder().encode(req) else { close(fd); passThrough() }
line.append(0x0A)
let wrote = line.withUnsafeBytes { buf -> Bool in
    var off = 0
    while off < buf.count {
        let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
        if n <= 0 { return false }
        off += n
    }
    return true
}
guard wrote else { close(fd); passThrough() }

// Wait for exactly one response line. The app decides how long to hold (e.g. while the user
// answers from their phone); the agent's own hook timeout bounds us from the outside.
var response = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    response.append(contentsOf: buf[0..<n])
    if response.contains(0x0A) { break }
}
close(fd)

guard let nl = response.firstIndex(of: 0x0A),
      let resp = try? JSONDecoder().decode(HookWire.Response.self, from: response[..<nl]) else { passThrough() }

if let out = resp.stdout, !out.isEmpty {
    FileHandle.standardOutput.write(Data(out.utf8))
}
if let err = resp.stderr, !err.isEmpty {
    FileHandle.standardError.write(Data(err.utf8))
}
fflush(stdout)
exit(resp.exitCode)
