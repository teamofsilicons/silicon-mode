import Foundation
#if canImport(Darwin)
import Darwin
#endif

// silicon-mode-hook <agent> [event]
//
// Called by agent hook systems (Claude Code / Codex `hooks`, …). Forwards the hook payload to the
// Silicon Mode app over ~/.silicon-mode/run/hook.sock and relays its answer.
//
// Contract: never break the agent. If the app isn't running, or anything at all goes wrong, exit
// 0 with no output, exactly as if no hook were installed.
// - Observation events (UserPromptSubmit, Stop, Notification, …) are fire-and-forget: write the
//   request line and exit without waiting.
// - PermissionRequest waits for one response line. The app decides how long to hold it (the
//   agent's own hook timeout bounds us from outside); an empty pass-through response, a closed
//   socket, or a malformed reply all mean "no decision" → the agent's own prompt decides.

signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments
let agent = args.count > 1 ? args[1] : "unknown"
let argEvent = args.count > 2 ? args[2] : nil

if agent == "--version" || agent == "-v" {
    print("silicon-mode-hook \(HookWire.version)")
    exit(0)
}

func passThrough() -> Never { exit(0) }

// Connect first: when the app isn't running we are done in a couple of milliseconds.
let path = HookWire.socketPath
var addr = sockaddr_un()
let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
guard path.utf8.count < sunPathSize else { passThrough() }
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: Array(path.utf8) + [0])
}
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { passThrough() }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
let rc = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard rc == 0 else { close(fd); passThrough() }

// Agents send one JSON object on stdin.
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = String(decoding: input, as: UTF8.self)

// Blocking only for permission prompts (event from argv, else sniffed from the payload).
let event = argEvent ?? (payload.contains("\"PermissionRequest\"") ? "PermissionRequest" : nil)
let blocking = event == "PermissionRequest"

var env: [String: String] = [:]
let environment = ProcessInfo.processInfo.environment
for k in HookWire.forwardedEnv { if let v = environment[k] { env[k] = v } }

let req = HookWire.Request(agent: agent, event: event, payload: payload, ppid: getppid(),
                           cwd: FileManager.default.currentDirectoryPath, env: env)
guard var line = try? JSONEncoder().encode(req) else { close(fd); passThrough() }
line.append(0x0A)
let wrote = line.withUnsafeBytes { buf -> Bool in
    var off = 0
    while off < buf.count {
        let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}
guard wrote, blocking else { close(fd); passThrough() }

// Wait for exactly one response line.
var response = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buf, buf.count)
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { break }
    response.append(contentsOf: buf[0..<n])
    if response.contains(0x0A) { break }
    if response.count > 16 << 20 { break }
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
exit(resp.exitCode)
