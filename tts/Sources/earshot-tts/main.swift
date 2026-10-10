// earshot-tts: Kokoro speech for Earshot, on this Mac.
//
//   earshot-tts speak --socket PATH --out FILE [--voice NAME] [--timeout SECS]
//       Reads one line from stdin and writes it to FILE as a WAV. Asks the
//       server on PATH. When none answers, it starts one and asks again, and
//       when that fails too, it makes the line itself. Exit 0: FILE is ready.
//   earshot-tts serve --socket PATH
//       Keeps Kokoro loaded and answers on PATH, one request at a time. Exits
//       after EARSHOT_KOKORO_IDLE_SECS (default 600) without a request, and
//       when one request takes over EARSHOT_KOKORO_REQUEST_SECS (default 15),
//       so a hung Core ML call does not block every later line.
//   earshot-tts prepare [--voice NAME]
//       Loads both runtimes and the voice once, downloading what is missing.
//       Setup and the rebuild after an update run it, so the legacy retry
//       never downloads while you work. Exit 3: only the legacy runtime failed.
//   earshot-tts voices
//       The English voices, one per line.
//
// A request is one line of JSON each way:
//   {"text": "...", "voice": "af_heart", "out": "/path/line.wav"}
//   {"ok": true}   or   {"ok": false, "error": "..."}
import Darwin
import FluidAudio
import Foundation

let defaultVoice = "af_heart"
let env = ProcessInfo.processInfo.environment

struct Request: Codable { let text: String; let voice: String; let out: String }
struct Reply: Codable { let ok: Bool; var error: String? = nil }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - Kokoro

/// Kokoro v3. A few inputs make v3 throw ("Invalid audio output"), so those
/// get a second try on the legacy runtime, which loads only then.
final class Speaker {
    private let v3 = KokoroAneManager(version: .v3)
    private var legacy: KokoroAneManager?
    private var legacyFailed = false   // try loading it once per process, not per line

    func load(voice: String = defaultVoice) async throws {
        try await v3.initialize(preloadVoices: [defaultVoice, voice])
    }

    /// The first long line after a short one is slow, so warm up with both.
    func warmUp() async {
        _ = try? await v3.synthesize(text: "Ready.", voice: defaultVoice)
        _ = try? await v3.synthesize(
            text: "Still on the billing service, about six minutes in. Latest step: run the invoice tests again.",
            voice: defaultVoice)
    }

    func speak(_ text: String, voice: String, to path: String) async throws {
        let wav: Data
        do {
            wav = try await v3.synthesize(text: text, voice: voice)
        } catch {
            guard !legacyFailed else { throw error }
            if legacy == nil {
                do {
                    let m = KokoroAneManager(version: .legacy)
                    try await m.initialize(preloadVoices: [voice])
                    legacy = m
                } catch {
                    legacyFailed = true
                    throw error
                }
            }
            wav = try await legacy!.synthesize(text: text, voice: voice)
        }
        try wav.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Loads the legacy runtime and the voice too, for `prepare`.
    func loadLegacy(voice: String) async throws {
        let m = KokoroAneManager(version: .legacy)
        try await m.initialize(preloadVoices: [defaultVoice, voice])
        legacy = m
    }
}

// MARK: - Socket

/// sun_path holds 104 bytes on macOS, the last one the terminating zero.
func fitsSocket(_ path: String) -> Bool { path.utf8.count < 104 }

func socketAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        guard bytes.count < buf.count else { fail("Socket path too long: \(path)") }
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    return addr
}

func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var addr = socketAddress(path)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func readLine(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 10 { return data }
        data.append(byte)
        if data.count > 1 << 20 { return nil }
    }
    return data.isEmpty ? nil : data
}

func writeLine<T: Encodable>(_ fd: Int32, _ value: T) -> Bool {
    guard var data = try? JSONEncoder().encode(value) else { return false }
    data.append(10)
    return data.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

// MARK: - serve

func serve(_ path: String) async -> Never {
    // Absolute, because the server leaves the folder it was started in: it can
    // live for hours, and should not keep a project folder in use.
    let socketPath = URL(fileURLWithPath: path).standardizedFileURL.path
    chdir("/")
    // One server per socket. The lock lasts as long as this process does.
    let lock = open(socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    unlink(socketPath)   // left by a server that crashed
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0,
          withAddress(socketPath, { bind(fd, $0, $1) }) == 0,
          listen(fd, 32) == 0
    else { fail("Can't listen on \(socketPath)") }
    // Clients that connect now wait in the queue while Kokoro loads.
    let speaker = Speaker()
    do { try await speaker.load() } catch {
        unlink(socketPath)
        fail("Kokoro didn't load: \(error)")
    }
    await speaker.warmUp()
    let idleMs = Int32(min(Int(env["EARSHOT_KOKORO_IDLE_SECS"] ?? "") ?? 600, 86_400) * 1000)
    let requestLimit = Double(env["EARSHOT_KOKORO_REQUEST_SECS"] ?? "") ?? 15
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, idleMs)
        if ready < 0 { continue }   // interrupted: wait again, don't block in accept
        if ready == 0 {
            // Idle: let the next server take over at once. A client that
            // connected just now gets EOF and starts one.
            unlink(socketPath)
            flock(lock, LOCK_UN)
            _exit(0)
        }
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        var tv = timeval(tv_sec: 5, tv_usec: 0)   // a client that never sends
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reply = Reply(ok: false, error: "bad request")
        if let line = readLine(c), let req = try? JSONDecoder().decode(Request.self, from: line) {
            // Quit when this takes too long. The socket goes first, so the
            // next line starts a fresh server; the lock goes with the process.
            let watchdog = DispatchWorkItem {
                FileHandle.standardError.write(Data("A line took over \(requestLimit) s, quitting\n".utf8))
                unlink(socketPath)
                _exit(1)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + requestLimit, execute: watchdog)
            do {
                try await speaker.speak(req.text, voice: req.voice, to: req.out)
                reply = Reply(ok: true)
            } catch { reply = Reply(ok: false, error: "\(error)") }
            watchdog.cancel()
        }
        _ = writeLine(c, reply)
        close(c)
    }
}

// MARK: - speak

enum Answer { case ok, failed(String), noServer }

/// Sends one request. noServer: nothing listens, or it died before replying.
func ask(_ socketPath: String, _ req: Request) -> Answer {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .noServer }
    defer { close(fd) }
    guard withAddress(socketPath, { connect(fd, $0, $1) }) == 0, writeLine(fd, req),
          let line = readLine(fd), let reply = try? JSONDecoder().decode(Reply.self, from: line)
    else { return .noServer }
    return reply.ok ? .ok : .failed(reply.error ?? "unknown error")
}

/// Starts a server in its own session, so it outlives this process and the hook.
func startServer(_ socketPath: String) {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // This runs on a worker thread that blocks signals. Without a clean mask
    // and default handlers, the server would ignore the TERM that a rebuild sends.
    var none = sigset_t(), all = sigset_t()
    sigemptyset(&none)
    sigfillset(&all)
    posix_spawnattr_setsigmask(&attr, &none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var files: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&files)
    posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&files, 2, socketPath + ".log", O_WRONLY | O_CREAT | O_APPEND, 0o600)
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("serve"), strdup("--socket"), strdup(socketPath), nil]
    var pid: pid_t = 0
    posix_spawn(&pid, exe, &files, &attr, argv, environ)
    posix_spawn_file_actions_destroy(&files)
    posix_spawnattr_destroy(&attr)
}

func speakCommand() async -> Never {
    guard let socketPath = option("--socket"), let out = option("--out") else {
        fail("Usage: earshot-tts speak --socket PATH --out FILE [--voice NAME] [--timeout SECS]")
    }
    // The server runs in another folder, so a relative path means ours.
    let outPath = URL(fileURLWithPath: out).standardizedFileURL.path
    let voice = option("--voice") ?? defaultVoice
    let timeout = Double(option("--timeout") ?? "") ?? 20
    // One limit for everything below, including a hung Core ML call. _exit,
    // because exit() would run cleanup while Core ML may still be working.
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        FileHandle.standardError.write(Data("Timed out after \(Int(timeout)) s\n".utf8))
        _exit(1)
    }
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("Nothing to say") }
    let req = Request(text: text, voice: voice, out: outPath)

    // A path too long for a socket cannot have a server: make the line here.
    var answer = fitsSocket(socketPath) ? ask(socketPath, req) : .noServer
    if fitsSocket(socketPath), case .noServer = answer {
        // Start a server, and again each second: one that is just exiting
        // still holds the lock, so the first new one can give up at once.
        let start = Date()
        var lastStart = Date.distantPast
        repeat {
            if Date().timeIntervalSince(lastStart) >= 1 {
                startServer(socketPath)
                lastStart = Date()
            }
            usleep(100_000)
            answer = ask(socketPath, req)
            if case .noServer = answer {} else { break }
        } while Date().timeIntervalSince(start) < 5
    }
    switch answer {
    case .ok: exit(0)
    case .failed(let message): fail(message)
    case .noServer:
        // No server came up, or it died mid-line: make this line here.
        let speaker = Speaker()
        do {
            try await speaker.load()
            try await speaker.speak(text, voice: voice, to: outPath)
            exit(0)
        } catch { fail("\(error)") }
    }
}

// MARK: - main

signal(SIGPIPE, SIG_IGN)
switch CommandLine.arguments.dropFirst().first {
case "speak": await speakCommand()
case "serve":
    guard let socketPath = option("--socket") else { fail("Usage: earshot-tts serve --socket PATH") }
    await serve(socketPath)
case "prepare":
    let voice = option("--voice") ?? defaultVoice
    let speaker = Speaker()
    do { try await speaker.load(voice: voice) } catch { fail("\(error)") }
    do { try await speaker.loadLegacy(voice: voice) } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(3)
    }
    print("ready")
case "voices": KokoroAneConstants.englishVoices.forEach { print($0) }
default: fail("Usage: earshot-tts speak|serve|voices (see the comment at the top of main.swift)")
}
