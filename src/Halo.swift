// Halo — animated project identities around Claude Code windows in Ghostty.
//
// Reads session records written by ~/.claude/hooks/halo-identity.js, maps each Claude
// session to its Ghostty window (tty -> window via Ghostty's AppleScript, frames via
// Accessibility) and, per project identity, draws:
//   * an animated outline + glow *outside* the window edge,
//   * an animated aurora *behind* the window, seen through Ghostty's translucent background,
//   * the terminal colours: background + cursor (OSC 11/12) and the tmux bar/borders.
// Everything is event-driven (AX notifications, workspace notifications, a directory watch,
// process-exit sources): no polling loop. Only the focused window animates; Core Animation
// runs the animation in the window server, so the app itself stays idle.
//
//   Halo                         run the overlay app
//   Halo --preview out.png [t] [--boom]   render every identity to a contact sheet (no window needed);
//                                          --boom shows the Return explosion t seconds in,
//                                          --focus the focus-in animation

import AppKit
import ApplicationServices
import QuartzCore
import Metal

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configDir = home + "/.config/halo"
let configPath = configDir + "/identities.json"
let sessionsDir = home + "/.cache/halo/sessions"
let tmuxBin = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
let ghosttyID = "com.mitchellh.ghostty"

let debug = FileManager.default.fileExists(atPath: configDir + "/debug")
func dlog(_ s: @autoclosure () -> String) { if debug { log("debug: " + s()) } }

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let path = home + "/Library/Logs/Halo.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
}

// MARK: - Config

enum Style: String {
    case flow     // the palette flowing around the window
    case dual     // outline and glow counter-rotate: shimmering interference
    case comet    // a white-hot head dragging a tail through the palette
    case twin     // two comets chasing each other
    case breathe  // flow + a slow breathing glow
    static func parse(_ s: String?) -> Style {
        switch s ?? "" {
        case "spectrum": return .flow    // names used by the first version
        case "spark": return .comet
        case "pulse": return .breathe
        default: return Style(rawValue: s ?? "") ?? .flow
        }
    }
}

struct Identity: Equatable {
    let name: String
    let hex: [String]
    let colors: [CGColor]
    let style: Style
    let bgHex: String
    let period: Double?
}

struct Settings: Equatable {
    var cornerRadius: CGFloat = 16
    var glow: CGFloat = 26
    var line: CGFloat = 2
    var aurora = true
}

func parseHex(_ s: String) -> (CGFloat, CGFloat, CGFloat)? {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return (CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255)
}

func cgColor(_ s: String, alpha: CGFloat = 1) -> CGColor? {
    guard let (r, g, b) = parseHex(s) else { return nil }
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func mix(_ base: String, _ accent: String, _ t: CGFloat) -> String {
    guard let a = parseHex(base), let b = parseHex(accent) else { return base }
    func ch(_ x: CGFloat, _ y: CGFloat) -> Int { Int(((x + (y - x) * t) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", ch(a.0, b.0), ch(a.1, b.1), ch(a.2, b.2))
}

/// identities in file order (JSONSerialization loses key order, so the keys are re-read from the text).
func loadConfig() -> (identities: [String: Identity], order: [String], settings: Settings)? {
    guard let data = FileManager.default.contents(atPath: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var settings = Settings()
    if let s = json["settings"] as? [String: Any] {
        if let v = s["cornerRadius"] as? Double { settings.cornerRadius = v }
        if let v = s["glow"] as? Double { settings.glow = v }
        if let v = s["line"] as? Double { settings.line = v }
        if let v = s["aurora"] as? Bool { settings.aurora = v }
    }
    var identities: [String: Identity] = [:]
    for (name, raw) in (json["identities"] as? [String: Any]) ?? [:] {
        guard let d = raw as? [String: Any], let hex = d["colors"] as? [String] else { continue }
        let colors = hex.compactMap { cgColor($0) }
        guard colors.count == hex.count, !colors.isEmpty else { continue }
        identities[name] = Identity(name: name, hex: hex, colors: colors, style: Style.parse(d["style"] as? String),
                                    bgHex: (d["bg"] as? String) ?? mix("#060616", hex[0], 0.12),
                                    period: d["period"] as? Double)
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    var order: [String] = []
    if let start = text.range(of: "\"identities\"") {
        let re = try! NSRegularExpression(pattern: "\\n    \"([^\"]+)\"\\s*:")
        let tail = String(text[start.upperBound...])
        for m in re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
            if let r = Range(m.range(at: 1), in: tail) { let n = String(tail[r]); if identities[n] != nil, !order.contains(n) { order.append(n) } }
        }
    }
    for n in identities.keys.sorted() where !order.contains(n) { order.append(n) }
    return (identities, order, settings)
}

// MARK: - Sessions

struct Session {
    let id: String
    let pid: pid_t
    let tty: String
    let tmux: String?
    let identity: String?
    let project: String?
    let modified: Date
}

func loadSessions() -> [Session] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
    var out: [Session] = []
    for name in names where name.hasSuffix(".json") {
        let path = sessionsDir + "/" + name
        guard let data = fm.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = j["pid"] as? Int, let tty = j["tty"] as? String else { continue }
        if kill(pid_t(pid), 0) != 0 && errno == ESRCH { try? fm.removeItem(atPath: path); continue }
        let mod = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        out.append(Session(id: String(name.dropLast(5)), pid: pid_t(pid), tty: tty,
                           tmux: j["tmux"] as? String, identity: j["identity"] as? String,
                           project: j["project"] as? String, modified: mod))
    }
    return out
}

@discardableResult
func run(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Terminal tty -> session. Inside tmux the window's tty is the tmux *client* tty.
func ttySessions(_ sessions: [Session]) -> [String: Session] {
    var clients: [String: [String]] = [:]
    if sessions.contains(where: { $0.tmux != nil }), FileManager.default.isExecutableFile(atPath: tmuxBin) {
        for line in run(tmuxBin, ["list-clients", "-F", "#{session_id} #{client_tty}"]).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2 { clients[String(parts[0]), default: []].append(String(parts[1])) }
        }
    }
    var map: [String: Session] = [:]
    for s in sessions.sorted(by: { $0.modified < $1.modified }) { // newest wins
        if let t = s.tmux { for c in clients[t] ?? [] { map[c] = s } } else { map[s.tty] = s }
    }
    return map
}

// MARK: - AppleScript: terminal window -> tty

func appleScript(_ src: String) -> [[String]] {
    var err: NSDictionary?
    guard let result = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else {
        if let err { log("applescript error: \(err)") }
        return []
    }
    return result.split(separator: "\n").map { $0.components(separatedBy: "\t") }
}

/// Ghostty: (window title, tty of the focused terminal of the selected tab), front to back.
/// (`tab` is a Ghostty class inside this tell block, hence `character id 9` for the separator.)
func ghosttyWindows() -> [(title: String, tty: String)] {
    appleScript("""
    tell application id "\(ghosttyID)"
      set out to {}
      repeat with w in windows
        try
          set end of out to (name of w) & (character id 9) & (tty of focused terminal of selected tab of w)
        end try
      end repeat
      set AppleScript's text item delimiters to linefeed
      return out as text
    end tell
    """).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
}

// MARK: - Accessibility helpers

func axAttr<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? T
}

func axWindowID(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
}

/// Title without Claude's leading spinner glyph ("✳ Topic" / "✻ Topic" -> "Topic").
func titleKey(_ t: String) -> String {
    String(t.drop(while: { !$0.isLetter && !$0.isNumber }))
}

/// AX frame (top-left origin) -> Cocoa frame (bottom-left origin of the primary screen).
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv: AXValue = axAttr(el, kAXPositionAttribute), let sv: AXValue = axAttr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv, .cgPoint, &p)
    AXValueGetValue(sv, .cgSize, &s)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
}

/// Stage Manager parks windows in its side strip by scaling them down: the window server reports the
/// thumbnail, Accessibility keeps the real size. Parked, or flying to / from the strip: no halo.
func isParked(cg: CGSize, ax: CGRect?) -> Bool {
    guard let ax else { return false }
    return abs(ax.width - cg.width) > 2 || abs(ax.height - cg.height) > 2
}

// MARK: - The identity layers (shared by the live overlay and the preview renderer)

/// Soft white dot, tinted per emitter cell.
let sparkImage: CGImage? = {
    let n = 24, space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray,
                             locations: [0, 0.25, 1]) else { return nil }
    let c = CGPoint(x: Double(n) / 2, y: Double(n) / 2)
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: Double(n) / 2, options: [])
    return ctx.makeImage()
}()

final class HaloLayers {
    let root = CALayer()
    // aurora: inside the window rect, behind the terminal (visible through its translucency)
    let aurora = CALayer(), stage = CALayer(), swirl = CAGradientLayer()
    var blobs: [CAGradientLayer] = []
    // outline: crisp line on the edge + soft glow outside it
    let glowBox = CALayer(), glowPulse = CALayer(), glowGrad = CAGradientLayer(), glowMask = CALayer()
    let lineBox = CALayer(), lineGrad = CAGradientLayer(), lineMask = CAShapeLayer()
    // typing impacts: a white flash on the outline + coloured ripples expanding outward
    let flash = CAShapeLayer()
    var ripples: [CAShapeLayer] = []
    private var rippleIndex = 0
    // Return: sparks off the whole outline + a blast of light through the background
    let sparks = CAEmitterLayer()
    let burst = CAGradientLayer()
    // paste: a stream of light dots flows around the outline
    let dots = CAShapeLayer()
    private(set) var identity: Identity?
    private(set) var settings = Settings()
    private var maskSize = CGSize.zero
    private var focused: Bool?
    private var glowClockwise = true

    init() {
        for l in [glowGrad, lineGrad, swirl] { l.type = .conic; l.startPoint = CGPoint(x: 0.5, y: 0.5); l.endPoint = CGPoint(x: 0.5, y: 0) }
        stage.anchorPoint = .zero
        stage.bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        aurora.masksToBounds = true
        aurora.cornerCurve = .continuous
        aurora.addSublayer(stage)
        stage.addSublayer(swirl)
        for _ in 0..<3 {
            let b = CAGradientLayer()
            b.type = .radial
            b.startPoint = CGPoint(x: 0.5, y: 0.5)
            b.endPoint = CGPoint(x: 1, y: 1)
            b.bounds = CGRect(x: 0, y: 0, width: 900, height: 900)
            blobs.append(b)
            stage.addSublayer(b)
        }
        glowPulse.addSublayer(glowGrad)
        glowBox.addSublayer(glowPulse)
        glowBox.mask = glowMask
        lineBox.addSublayer(lineGrad)
        lineBox.mask = lineMask
        lineMask.fillColor = nil
        lineMask.strokeColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(aurora)
        root.addSublayer(glowBox)
        root.addSublayer(lineBox)
        flash.fillColor = nil
        flash.strokeColor = CGColor(gray: 1, alpha: 1)
        flash.opacity = 0
        root.addSublayer(flash)
        for _ in 0..<8 {
            let r = CAShapeLayer()
            r.fillColor = nil
            r.opacity = 0
            ripples.append(r)
            root.addSublayer(r)
        }
        burst.type = .radial
        burst.startPoint = CGPoint(x: 0.5, y: 0.5)
        burst.endPoint = CGPoint(x: 1, y: 1)
        burst.opacity = 0
        aurora.addSublayer(burst)
        sparks.emitterShape = .rectangle
        sparks.emitterMode = .outline
        sparks.renderMode = .additive
        sparks.birthRate = 0
        root.addSublayer(sparks)
        dots.fillColor = nil
        dots.lineCap = .round
        dots.lineDashPattern = [0.01, 12]
        dots.opacity = 0
        root.addSublayer(dots)
    }

    /// Room around the window for the glow, the shockwaves and the sparks.
    var pad: CGFloat { settings.glow + 70 }

    func configure(_ id: Identity, _ s: Settings) {
        guard id != identity || s != settings else { return }
        identity = id
        settings = s
        maskSize = .zero
        let c = id.colors
        func at(_ i: Int) -> CGColor { c[((i % c.count) + c.count) % c.count] }
        func dim(_ col: CGColor, _ a: CGFloat) -> CGColor { col.copy(alpha: a)! }
        for l in [glowPulse, glowGrad, lineGrad, swirl, stage] + blobs { l.removeAllAnimations() }

        // Outline gradient
        switch id.style {
        case .comet, .twin:
            let reps = id.style == .twin ? 2 : 1
            var colors: [CGColor] = [], locs: [Double] = []
            for r in 0..<reps {
                let o = Double(r) / Double(reps), span = 1 / Double(reps)
                // dim multi-colour track, then a tail through the palette into a white-hot head
                colors += [dim(at(0), 0.14), dim(at(c.count / 2), 0.14)]
                locs += [o, o + span * 0.42]
                let tail = Array(c.prefix(4))
                for (k, tc) in tail.enumerated() {
                    colors.append(tc)
                    locs.append(o + span * (0.58 + 0.34 * Double(k) / Double(max(tail.count - 1, 1))))
                }
                colors.append(CGColor(gray: 1, alpha: 1)); locs.append(o + span * 0.965)
                colors.append(dim(at(0), 0.14)); locs.append(o + span)
            }
            for l in [glowGrad, lineGrad] { l.colors = colors; l.locations = locs.map { NSNumber(value: $0) } }
        default:
            for l in [glowGrad, lineGrad] { l.colors = c + [c[0]]; l.locations = nil }
        }
        let defaults: [Style: Double] = [.flow: 10, .dual: 9, .comet: 3.6, .twin: 5.5, .breathe: 12]
        let period = id.period ?? defaults[id.style]!
        spin(lineGrad, period, clockwise: true)
        glowClockwise = id.style != .dual
        spin(glowGrad, id.style == .dual ? period * 1.7 : period, clockwise: glowClockwise)
        if id.style == .breathe { breathe(glowPulse, from: 0.3, to: 1, period: 2.8) }
        for (i, r) in ripples.enumerated() { r.strokeColor = at(i) } // rainbow identities ripple in every colour
        dots.strokeColor = CGColor(red: 0.75, green: 1, blue: 1, alpha: 1)
        dots.shadowColor = at(0)
        let n = min(4, c.count)
        sparks.emitterCells = (0..<n).map { i in
            let cell = CAEmitterCell()
            cell.contents = sparkImage
            cell.color = at(i)
            cell.birthRate = Float(4000 / n)
            cell.lifetime = 0.7
            cell.lifetimeRange = 0.25
            cell.velocity = 80
            cell.velocityRange = 50
            cell.emissionRange = .pi * 2
            cell.scale = 0.2
            cell.scaleRange = 0.1
            cell.scaleSpeed = -0.22
            cell.alphaSpeed = -1.35
            return cell
        }
        burst.colors = [CGColor(gray: 1, alpha: 1), dim(at(0), 1), dim(at(1), 0.6), dim(at(2), 0)]
        burst.locations = [0, 0.14, 0.45, 1]

        // Aurora: deep base, a slow colour swirl and three drifting light blobs
        aurora.isHidden = !s.aurora
        aurora.backgroundColor = cgColor(id.bgHex)
        swirl.colors = c.map { dim($0, 0.75) } + [dim(c[0], 0.75)]
        swirl.opacity = 0.6
        swirl.frame = stage.bounds.insetBy(dx: -420, dy: -420)
        spin(swirl, 70, clockwise: false, fps: 20)
        let paths: [[CGPoint]] = [
            [CGPoint(x: 200, y: 250), CGPoint(x: 720, y: 300), CGPoint(x: 800, y: 720), CGPoint(x: 280, y: 800)],
            [CGPoint(x: 820, y: 800), CGPoint(x: 240, y: 640), CGPoint(x: 360, y: 180), CGPoint(x: 860, y: 320)],
            [CGPoint(x: 520, y: 480), CGPoint(x: 120, y: 420), CGPoint(x: 520, y: 900), CGPoint(x: 900, y: 540)],
        ]
        for (i, b) in blobs.enumerated() {
            let col = at(i * max(1, c.count / 3) + (i == 2 ? 1 : 0))
            b.colors = [dim(col, 1), dim(col, 0.6), dim(col, 0)]
            b.locations = [0, 0.45, 1]
            b.position = paths[i][0]
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = (paths[i] + [paths[i][0]]).map { NSValue(point: $0) }
            drift.calculationMode = .cubic
            drift.duration = 19 + Double(i) * 6.5
            drift.repeatCount = .infinity
            cap(drift, 20)
            b.add(drift, forKey: "drift")
            breathe(b, from: 0.45, to: 1, period: 6 + Double(i) * 2.3, fps: 20)
        }

        let f = focused ?? false
        focused = nil
        setFocused(f, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Slow ambient motion doesn't need 120 fps: capping it divides the window server's work
    /// (every aurora frame also re-blurs Ghostty's translucent background).
    private func cap(_ a: CAAnimation, _ fps: Float) {
        a.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
    }

    private func spin(_ l: CALayer, _ period: Double, clockwise: Bool, fps: Float = 30) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = (clockwise ? -2 : 2) * Double.pi
        a.duration = period
        a.repeatCount = .infinity
        cap(a, fps)
        l.add(a, forKey: "spin")
    }

    private func breathe(_ l: CALayer, from: Float, to: Float, period: Double, fps: Float = 30) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cap(a, fps)
        l.add(a, forKey: "breathe")
    }

    /// size: the whole overlay (window frame grown by `pad` on every side).
    /// live: mid-drag/resize, keep the blurred glow image and stretch it (rebuilt when the drag ends).
    func setSize(_ size: CGSize, scale: CGFloat, live: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        root.frame = bounds
        let edge = bounds.insetBy(dx: pad, dy: pad)
        aurora.frame = edge
        aurora.cornerRadius = settings.cornerRadius
        stage.position = .zero
        stage.transform = CATransform3DMakeScale(edge.width / 1000, edge.height / 1000, 1)
        let side = hypot(bounds.width, bounds.height) + 4
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        for l in [glowBox, glowPulse, lineBox] { l.frame = bounds }
        glowGrad.frame = square
        lineGrad.frame = square
        sparks.frame = bounds
        sparks.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        sparks.emitterSize = edge.size
        let blast = max(edge.width, edge.height) * 2.2
        burst.bounds = CGRect(x: 0, y: 0, width: blast, height: blast)
        burst.position = CGPoint(x: edge.width / 2, y: min(90, edge.height / 4)) // Claude's input box, near the bottom
        if size != maskSize {
            rebuildPaths(bounds)
            if live { glowMask.frame = bounds } else { rebuildGlow(bounds, scale: scale) }
        }
        CATransaction.commit()
    }

    private func rebuildPaths(_ bounds: CGRect) {
        let r = settings.cornerRadius
        let edge = bounds.insetBy(dx: pad, dy: pad)
        let lw = settings.line
        lineMask.lineWidth = lw
        let lineRect = edge.insetBy(dx: -lw / 2, dy: -lw / 2)
        let path = CGPath(roundedRect: lineRect, cornerWidth: r + lw / 2, cornerHeight: r + lw / 2, transform: nil)
        lineMask.path = path
        lineMask.frame = bounds
        for l in [flash] + ripples { l.path = path; l.lineWidth = lw * 1.5; l.frame = bounds }
        dots.path = path
        dots.lineWidth = lw * 2.5
        dots.frame = bounds
    }

    private func rebuildGlow(_ bounds: CGRect, scale: CGFloat) {
        maskSize = bounds.size
        let r = settings.cornerRadius
        let edge = bounds.insetBy(dx: pad, dy: pad)
        let lw = settings.line
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        let ring = CGPath(roundedRect: edge, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.setShadow(offset: .zero, blur: settings.glow * scale * 0.9, color: CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(lw * 3)
        for _ in 0..<2 { ctx.addPath(ring); ctx.strokePath() }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setBlendMode(.clear)
        ctx.addPath(ring)
        ctx.fillPath()
        glowMask.contents = ctx.makeImage()
        glowMask.contentsScale = scale
        glowMask.frame = bounds
    }

    /// Focused: full brightness, animated. Unfocused: dimmer and frozen (no compositing work).
    func setFocused(_ f: Bool, reduceMotion: Bool) {
        guard f != focused else { return }
        let was = focused
        focused = f
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        glowBox.opacity = f ? 0.85 : 0.4
        lineBox.opacity = f ? 1.0 : 0.6
        CATransaction.commit()
        let animate = f && !reduceMotion
        for l in [glowPulse, lineGrad, stage] as [CALayer] { animate ? resume(l) : pause(l) }
        if animate && was == false { whoosh() }
    }

    private var canImpact: Bool {
        identity != nil && focused == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A decaying bump on top of whatever the layer is doing; bumps stack, so fast typing builds a combo.
    private func additive(_ l: CALayer, _ key: String, _ from: Double, _ dur: Double) {
        let a = CABasicAnimation(keyPath: key)
        a.isAdditive = true
        a.fromValue = from
        a.toValue = 0
        a.duration = dur
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap(a, 60)
        l.add(a, forKey: nil)
    }

    /// A shockwave: the outline's twin flies `reach` points outward and fades.
    private func ring(reach: CGFloat, width: CGFloat, duration: Double, delay: Double) {
        let edge = root.bounds.insetBy(dx: pad, dy: pad)
        guard edge.width > 0, edge.height > 0 else { return }
        let r = ripples[rippleIndex % ripples.count]
        rippleIndex += 1
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DIdentity
        grow.toValue = CATransform3DMakeScale(1 + 2 * reach / edge.width, 1 + 2 * reach / edge.height, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = width
        thin.toValue = 0.5
        let g = CAAnimationGroup()
        g.animations = [grow, fade, thin]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap(g, 60)
        r.add(g, forKey: "ripple")
    }

    /// Focus arrives: the colours whoosh once around the outline and settle back into their flow.
    private func whoosh() {
        additive(lineGrad, "transform.rotation.z", .pi * 1.1, 0.7)
        additive(glowGrad, "transform.rotation.z", (glowClockwise ? 1 : -1) * .pi * 1.1, 0.7)
        additive(glowBox, "opacity", 0.2, 0.5)
    }

    /// Paste: a stream of light dots flows around the outline while the glow lifts.
    func pasteFlow() {
        guard canImpact else { return }
        let run = CABasicAnimation(keyPath: "lineDashPhase")
        run.fromValue = 0
        run.toValue = -240
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.12, 0.6, 1]
        let g = CAAnimationGroup()
        g.animations = [run, show]
        g.duration = 0.6
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap(g, 60)
        dots.add(g, forKey: "flow")
        additive(glowBox, "opacity", 0.25, 0.6)
    }

    /// Ctrl+U: the outline blinks out and comes straight back, as if wiped.
    func wipe() {
        guard canImpact else { return }
        additive(lineBox, "opacity", -0.7, 0.3)
        additive(glowBox, "opacity", -0.35, 0.3)
    }

    /// One keystroke: the glow breathes a little brighter and a faint sheen runs over the outline.
    /// Bumps stack, so steady typing holds the outline lit; it settles when you stop.
    func kick() {
        guard canImpact else { return }
        additive(glowBox, "opacity", 0.1, 0.35)
        additive(flash, "opacity", 0.18, 0.3)
    }

    /// Return: a supernova. The outline flares white and wobbles like jelly, four shockwaves fly off in
    /// the identity colours, hundreds of sparks burst off every edge, and a blast of light from the input
    /// box whirls the background. About a second of work per Return, nothing before or after.
    func explode() {
        guard canImpact else { return }
        additive(flash, "opacity", 1, 0.55)
        additive(glowBox, "opacity", 0.6, 0.8)
        for (l, amount) in [(glowBox, 0.05), (lineBox, 0.025)] as [(CALayer, Double)] {
            let wobble = CASpringAnimation(keyPath: "transform.scale")
            wobble.isAdditive = true
            wobble.fromValue = amount
            wobble.toValue = 0
            wobble.stiffness = 280
            wobble.damping = 9
            wobble.duration = wobble.settlingDuration
            cap(wobble, 60)
            l.add(wobble, forKey: nil)
        }
        for n in 0..<4 {
            ring(reach: 40 + 12 * CGFloat(n), width: settings.line * 4, duration: 0.85, delay: Double(n) * 0.07)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sparks.beginTime = CACurrentMediaTime()
        sparks.birthRate = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.sparks.birthRate = 0
            CATransaction.commit()
        }
        guard !aurora.isHidden else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.08
        grow.toValue = 1
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 1, 0.55, 0]
        light.keyTimes = [0, 0.08, 0.4, 1]
        let blast = CAAnimationGroup()
        blast.animations = [grow, light]
        blast.duration = 1.0
        cap(blast, 60)
        burst.add(blast, forKey: "blast")
        additive(swirl, "transform.rotation.z", .pi * 0.5, 1.4)
        additive(swirl, "opacity", 0.5, 1.0)
        for b in blobs { additive(b, "opacity", 0.5, 1.1) }
    }

    private func pause(_ l: CALayer) {
        guard l.speed != 0 else { return }
        let t = l.convertTime(CACurrentMediaTime(), from: nil)
        l.speed = 0
        l.timeOffset = t
    }

    private func resume(_ l: CALayer) {
        guard l.speed == 0 else { return }
        let paused = l.timeOffset
        l.speed = 1
        l.timeOffset = 0
        l.beginTime = 0
        l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
    }
}

// MARK: - Overlay window

/// The session name badge: a dark pill in the top-right of the terminal's title bar, project name in its
/// identity gradient, glowing gradient border. Its own tiny click-through window sits just ABOVE the
/// terminal (the halo sits below it). Focused: the colours flow and a shimmer crosses it every few
/// seconds (20 fps). Unfocused: still and a little dimmer.
final class Badge {
    let window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    let root = CALayer()
    private let glow = CALayer(), pill = CALayer(), shine = CAGradientLayer(), dot = CALayer()
    private let borderBox = CALayer(), borderGrad = CAGradientLayer(), borderMask = CAShapeLayer()
    private let textBox = CALayer(), textGrad = CAGradientLayer(), text = CATextLayer()
    private var key = ""
    private var size = CGSize.zero
    private var focused: Bool?
    static let margin: CGFloat = 14  // room for the glow

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal // ordered just above its terminal
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        view.layer!.addSublayer(root)
        glow.shadowOffset = .zero
        glow.shadowRadius = 9
        glow.shadowOpacity = 0.9
        pill.masksToBounds = true
        pill.addSublayer(shine)
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)]
        shine.opacity = 0
        borderMask.fillColor = nil
        borderMask.strokeColor = CGColor(gray: 0, alpha: 1)
        borderMask.lineWidth = 1.6
        borderBox.mask = borderMask
        borderBox.addSublayer(borderGrad)
        textBox.mask = text
        textBox.addSublayer(textGrad)
        for g in [borderGrad, textGrad] { g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5) }
        dot.shadowOffset = .zero
        dot.shadowRadius = 4
        dot.shadowOpacity = 1
        text.contentsScale = 2
        for l in [glow, pill, borderBox, dot, textBox] { root.addSublayer(l) }
    }

    func configure(name: String, _ id: Identity) {
        let k = name + "|" + id.name
        guard k != key else { return }
        key = k
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .heavy).fontDescriptor.withDesign(.rounded)!, size: 14)
            ?? NSFont.systemFont(ofSize: 14, weight: .heavy)
        let tw = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        let h: CGFloat = 26, dotD: CGFloat = 8, padL: CGFloat = 11, gap: CGFloat = 7, padR: CGFloat = 13
        let w = padL + dotD + gap + tw + padR
        size = CGSize(width: w + 2 * Badge.margin, height: h + 2 * Badge.margin)
        let c = id.colors
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        let r = CGRect(x: Badge.margin, y: Badge.margin, width: w, height: h)
        let path = CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        glow.frame = root.bounds
        glow.shadowPath = path
        glow.shadowColor = c[0]
        pill.frame = r
        pill.cornerRadius = h / 2
        pill.backgroundColor = cgColor(id.bgHex, alpha: 0.94)
        shine.frame = CGRect(x: -60, y: 0, width: 50, height: h)
        borderBox.frame = root.bounds
        borderMask.frame = root.bounds
        borderMask.path = CGPath(roundedRect: r.insetBy(dx: 0.8, dy: 0.8), cornerWidth: h / 2 - 0.8, cornerHeight: h / 2 - 0.8, transform: nil)
        dot.frame = CGRect(x: r.minX + padL, y: r.midY - dotD / 2, width: dotD, height: dotD)
        dot.cornerRadius = dotD / 2
        dot.backgroundColor = c[0]
        dot.shadowColor = c[0]
        text.string = name
        text.font = font
        text.fontSize = 14
        text.foregroundColor = CGColor(gray: 1, alpha: 1)
        let tx = r.minX + padL + dotD + gap
        textBox.frame = CGRect(x: tx, y: r.midY - 9.5, width: tw, height: 19)
        text.frame = textBox.bounds
        // colours twice over a span W, flowing left by W per cycle: seamless
        let cycle = Array(c) + Array(c) + [c[0]]
        let span = max(tw, 140)
        textGrad.colors = cycle
        textGrad.frame = CGRect(x: 0, y: 0, width: 2 * span, height: 19)
        borderGrad.colors = cycle
        borderGrad.frame = CGRect(x: 0, y: 0, width: 2 * max(size.width, 140), height: size.height)
        CATransaction.commit()
        for l in [textGrad, borderGrad] { l.removeAllAnimations() }
        flow(textGrad, span)
        flow(borderGrad, max(size.width, 140))
        let pass = CABasicAnimation(keyPath: "position.x")
        pass.fromValue = -40
        pass.toValue = w + 40
        pass.duration = 0.9
        pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let lit = CAKeyframeAnimation(keyPath: "opacity")
        lit.values = [0, 1, 1, 0]
        lit.keyTimes = [0, 0.15, 0.8, 1]
        lit.duration = 0.9
        let every = CAAnimationGroup()
        every.animations = [pass, lit]
        every.duration = 5
        every.repeatCount = .infinity
        every.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        shine.add(every, forKey: "shine")
        let f = focused ?? false
        focused = nil
        setFocused(f, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func flow(_ l: CALayer, _ span: CGFloat) {
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = 0
        a.toValue = -span
        a.duration = 6
        a.repeatCount = .infinity
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
        l.add(a, forKey: "flow")
    }

    /// Top-right of the terminal, vertically centred in its title bar.
    func place(in target: CGRect) {
        guard size != .zero else { return }
        let x = target.maxX - size.width + Badge.margin - 10
        let y = target.maxY - 14 - size.height / 2
        window.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    func setFocused(_ f: Bool, reduceMotion: Bool) {
        guard f != focused else { return }
        let was = focused
        focused = f
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        root.opacity = f ? 1 : 0.8
        CATransaction.commit()
        for l in [textGrad, borderGrad, shine] as [CALayer] { f && !reduceMotion ? resumeLayer(l) : pauseLayer(l) }
        if f && was == false && !reduceMotion { pop(1.14) }
    }

    /// A springy pop: on appearing and whenever its window gets focus.
    func pop(_ from: Double) {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = from
        a.toValue = 1
        a.stiffness = 320
        a.damping = 14
        a.duration = a.settlingDuration
        for l in [glow, pill, borderBox, dot, textBox] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.add(a, forKey: "pop")
        }
    }
}

func pauseLayer(_ l: CALayer) {
    guard l.speed != 0 else { return }
    let t = l.convertTime(CACurrentMediaTime(), from: nil)
    l.speed = 0
    l.timeOffset = t
}

func resumeLayer(_ l: CALayer) {
    guard l.speed == 0 else { return }
    let paused = l.timeOffset
    l.speed = 1
    l.timeOffset = 0
    l.beginTime = 0
    l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
}

/// AppKit keeps windows below the menu bar; the overlay must be free to extend past the screen edge,
/// or a terminal touching the top of the screen gets a halo shoved down by the glow margin.
final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class Halo {
    let window: NSWindow
    let layers = HaloLayers()
    let badge = Badge()

    init() {
        window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Normal level, ordered just below its terminal: over whatever lies behind the terminal, so the
        // outline and effects stay visible next to neighbouring windows.
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        view.layer!.addSublayer(layers.root)
    }

    private(set) var target = CGRect.null
    func setTarget(_ target: CGRect, live: Bool = false) {
        self.target = target
        badge.place(in: target)
        let frame = target.insetBy(dx: -layers.pad, dy: -layers.pad)
        window.setFrame(frame, display: false)
        layers.setSize(frame.size, scale: window.backingScaleFactor > 0 ? window.backingScaleFactor : 2, live: live)
    }

    /// Directly below the terminal window: the glow is outside its edge, the aurora shows through it.
    func show(below wid: CGWindowID) {
        window.order(.below, relativeTo: Int(wid))
        badge.window.order(.above, relativeTo: Int(wid))
    }
    func hide() { window.orderOut(nil); badge.window.orderOut(nil) }

    /// Another app's window can't be followed frame-perfectly, so while it moves or resizes the halo
    /// vanishes at once (no lagging ghost) and fades back in place once the window has settled.
    private(set) var moving = false
    func beginMove() {
        guard !moving else { return }
        moving = true
        fade(to: 0, duration: 0)
    }
    func endMove(at frame: CGRect) {
        moving = false
        setTarget(frame)
        fade(to: 1, duration: 0.25)
    }

    /// New or returning window (restored, back from the Stage Manager strip): fade in once it has landed.
    func appear() {
        fade(to: 1, duration: 0.3, from: 0, delay: 0.25)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { badge.pop(0.4) }
    }

    private func fade(to v: Float, duration: Double, from: Float? = nil, delay: Double = 0) {
        // the badge's window alpha follows the halo; its root opacity is kept for focus dimming
        let l = layers.root
        let start = from ?? l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.removeAnimation(forKey: "fade")
        l.opacity = v
        if duration > 0 {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = start
            a.toValue = v
            a.duration = duration
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(a, forKey: "fade")
        }
        CATransaction.commit()
        if duration == 0 {
            badge.window.alphaValue = CGFloat(v)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [badge] in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    badge.window.animator().alphaValue = CGFloat(v)
                }
            }
        }
    }
}

// MARK: - Controller

final class Controller: NSObject {
    var identities: [String: Identity] = [:]
    var settings = Settings()
    var observers: [pid_t: AXObserver] = [:]
    var observedWindows = Set<CGWindowID>()
    var windowPIDs: [CGWindowID: pid_t] = [:]
    var halos: [CGWindowID: Halo] = [:]
    var painted: [String: String] = [:]          // tty -> identity whose colours were sent
    var tmuxThemed: [String: String] = [:]       // tmux session id -> identity
    var ghosttyTTYs = Set<String>()                // ttys of Ghostty terminals (only these get OSC colours)
    var titleKeys: [CGWindowID: String] = [:]
    var elements: [CGWindowID: AXUIElement] = [:]
    var focusedWID: CGWindowID?
    var monitors: [Any] = []
    var dragTimer: Timer?
    var settle: [CGWindowID: DispatchWorkItem] = [:]
    var ttyForWindow: [CGWindowID: String] = [:]  // Ghostty windows with a halo -> their tty
    var pumpTimer: Timer?
    var pump: (tty: String, bg: String, until: CFTimeInterval)?
    var boom: (tty: String, start: CFTimeInterval, cursor: String)?
    var mark: (tty: String, cursor: String, until: CFTimeInterval)?  // paste / erase effect in progress
    var fastUntil: CFTimeInterval = 0
    var pumpFrame = 0
    var vanished: [CGWindowID: CFTimeInterval] = [:]  // being minimized: no halo until it's restored
    // What the last full rebuild learned (session + tty per Claude window, traffic-light buttons relative to
    // the window's top-left), so clicks and app switches never send Ghostty an Apple Event or AX query:
    // answering those right as you click into it is what made the click feel laggy.
    var known: [CGWindowID: (session: Session, tty: String)] = [:]
    var buttonOffsets: [CGWindowID: [CGRect]] = [:]
    var exitSources: [pid_t: DispatchSourceProcess] = [:]
    var dirSources: [DispatchSourceFileSystemObject] = []
    var pending = false
    var trustTimer: Timer?
    var lastSummary = ""

    func start() {
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            begin()
        } else {
            log("waiting for Accessibility permission")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.begin() }
            }
        }
    }

    private func begin() {
        log("started")
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(self, selector: #selector(schedule), name: name, object: nil)
        }
        nc.addObserver(self, selector: #selector(activated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(schedule), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        watch(sessionsDir)
        watch(configDir)
        // Typing impacts + window tracking. Only the timing of events (and which shortcut it was: Return,
        // Cmd-V, Ctrl-U, Cmd-M) is used; no text is read or recorded.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.keyDown(e) }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.mouseDown() }) { monitors.append(m) }
        rebuild()
    }

    private func watch(_ dir: String) {
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSources.append(src)
    }

    @objc func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.rebuild()
        }
    }

    // MARK: AX observation

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func observeWindow(_ el: AXUIElement, wid: CGWindowID, pid: pid_t) {
        guard !observedWindows.contains(wid), let obs = observers[pid] else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, me)
        }
        observedWindows.insert(wid)
    }

    func handle(_ element: AXUIElement, _ notification: String) {
        dlog("ax event \(notification) wid=\(axWindowID(element).map(String.init) ?? "-")")
        switch notification {
        case kAXMovedNotification, kAXResizedNotification:
            guard let wid = axWindowID(element), let halo = halos[wid] else { return }
            halo.beginMove()
            settleLater(wid, halo)
        case kAXWindowMiniaturizedNotification:
            if let wid = axWindowID(element) { vanish(wid) }
        case kAXWindowDeminiaturizedNotification:
            // let the restore animation finish, then the halo fades in around the landed window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.schedule() }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            focusChanged()
        case kAXTitleChangedNotification:
            // Spinner frames change the title constantly while Claude works; only a real change (tab switch) matters.
            guard let wid = axWindowID(element) else { return }
            let key = titleKey(axAttr(element, kAXTitleAttribute) ?? "")
            if titleKeys[wid] != key { titleKeys[wid] = key; schedule() }
        default:
            schedule()
        }
    }

    // MARK: Rebuild

    func rebuild() {
        if let cfg = loadConfig() { identities = cfg.identities; settings = cfg.settings }
        let sessions = loadSessions()
        watchExits(sessions)
        let byTTY = ttySessions(sessions)
        dlog("sessions=\(sessions.map { "\($0.tty)/\($0.tmux ?? "-")/\($0.identity ?? "-")" }) byTTY=\(byTTY.mapValues { $0.identity ?? "-" })")

        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == ghosttyID }
        for app in apps { observe(app) }
        let live = Set(apps.map { $0.processIdentifier })
        for pid in observers.keys where !live.contains(pid) { observers[pid] = nil }

        var onScreen: [CGWindowID: CGSize] = [:]
        for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard let n = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            onScreen[n] = r.size
        }

        var seen = Set<CGWindowID>()
        var wanted: [CGWindowID: (session: Session, element: AXUIElement, tty: String)] = [:]
        var found: [CGWindowID: (session: Session, tty: String)] = [:]
        let anySession = !byTTY.isEmpty
        for app in apps {
            let pid = app.processIdentifier
            let axWindows: [AXUIElement] = axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
            // Window -> tty, only asked when there is at least one live session (no AppleScript otherwise).
            var ghostty: [String: [String]] = [:]
            if anySession && !app.isHidden {
                let list = ghosttyWindows()
                dlog("ghostty applescript=\(list)")
                ghosttyTTYs = Set(list.map { $0.tty })
                for w in list { ghostty[titleKey(w.title), default: []].append(w.tty) }
            }
            for el in axWindows {
                guard let wid = axWindowID(el), (axAttr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole else { continue }
                seen.insert(wid)
                windowPIDs[wid] = pid
                elements[wid] = el
                observeWindow(el, wid: wid, pid: pid)
                var tty: String?
                let title = titleKey(axAttr(el, kAXTitleAttribute) ?? "")
                titleKeys[wid] = title
                if var list = ghostty[title], !list.isEmpty { tty = list.removeFirst(); ghostty[title] = list }
                let minimized: Bool = axAttr(el, kAXMinimizedAttribute) ?? false
                let fullScreen: Bool = axAttr(el, "AXFullScreen") ?? false
                dlog("ax wid=\(wid) tty=\(tty ?? "-") onscreen=\(onScreen[wid] != nil)")
                if let t = vanished[wid], !minimized, CACurrentMediaTime() - t > 1.0 { vanished[wid] = nil }
                guard let tty, let s = byTTY[tty], s.identity != nil else { continue }
                found[wid] = (s, tty)
                if let size = onScreen[wid], !isParked(cg: size, ax: axFrame(el)), !minimized, !fullScreen, vanished[wid] == nil {
                    wanted[wid] = (s, el, tty)
                    if buttonOffsets[wid] == nil, let f = axFrame(el) {
                        buttonOffsets[wid] = [kAXMinimizeButtonAttribute, kAXCloseButtonAttribute, kAXZoomButtonAttribute].compactMap { attr in
                            guard let b: AXUIElement = axAttr(el, attr), let bf = axFrame(b) else { return nil }
                            return bf.insetBy(dx: -2, dy: -2).offsetBy(dx: -f.minX, dy: -f.maxY)
                        }
                    }
                }
            }
        }
        for wid in Set(windowPIDs.keys).subtracting(seen) {
            windowPIDs[wid] = nil; observedWindows.remove(wid); titleKeys[wid] = nil; elements[wid] = nil; buttonOffsets[wid] = nil
        }
        known = found

        // Outlines + aurora
        for (wid, halo) in halos where wanted[wid] == nil { halo.hide(); halos[wid] = nil }
        for (wid, w) in wanted {
            if let f = axFrame(w.element) { place(wid, (w.session, w.tty), frame: f) }
        }

        // every Claude window we know, on screen or not: a window back from the Stage Manager strip is
        // re-attached by verify() without a rebuild, and its in-terminal effects need its tty
        ttyForWindow = found.mapValues { $0.tty }
        paintTerminals(byTTY)
        themeTmux(sessions)
        focusChanged()
        let summary = wanted.map { "\($0.key)=\($0.value.session.identity ?? "-")" }.sorted().joined(separator: " ")
        if summary != lastSummary { log("outlines: \(summary.isEmpty ? "none" : summary)"); lastSummary = summary }
    }

    /// Ghostty background + cursor in the identity colours (OSC 11/12); reset (OSC 111/112) when the session leaves.
    private func paintTerminals(_ byTTY: [String: Session]) {
        var want: [String: Identity] = [:]
        for (tty, s) in byTTY where ghosttyTTYs.contains(tty) {
            if let n = s.identity, let id = identities[n] { want[tty] = id }
        }
        for (tty, id) in want where painted[tty] != id.name {
            writeTTY(tty, "\u{1b}]11;\(id.bgHex)\u{7}\u{1b}]12;\(id.hex[0])\u{7}")
            painted[tty] = id.name
        }
        for tty in painted.keys where want[tty] == nil {
            writeTTY(tty, "\u{1b}]111\u{7}\u{1b}]112\u{7}")
            painted[tty] = nil
        }
    }

    /// The tmux bar and active pane border take the identity (Claude run inside tmux); unset when it leaves.
    private func themeTmux(_ sessions: [Session]) {
        var want: [String: Identity] = [:]
        for s in sessions.sorted(by: { $0.modified < $1.modified }) {
            guard let t = s.tmux else { continue }
            if let n = s.identity, let id = identities[n] { want[t] = id } else { want[t] = nil }
        }
        for (t, id) in want where tmuxThemed[t] != id.name {
            let a = id.hex[0], b = id.hex[min(1, id.hex.count - 1)]
            run(tmuxBin, ["set", "-t", t, "status-style", "bg=\(mix(id.bgHex, a, 0.22)),fg=#f0f0ff", ";",
                          "set", "-w", "-t", t, "window-status-current-style", "bg=\(a),fg=#05050a,bold", ";",
                          "set", "-w", "-t", t, "pane-active-border-style", "fg=\(b)", ";",
                          "set", "-w", "-t", t, "pane-border-style", "fg=\(mix(id.bgHex, a, 0.35))"])
            tmuxThemed[t] = id.name
        }
        for t in tmuxThemed.keys where want[t] == nil {
            run(tmuxBin, ["set", "-u", "-t", t, "status-style", ";",
                          "set", "-u", "-w", "-t", t, "window-status-current-style", ";",
                          "set", "-u", "-w", "-t", t, "pane-active-border-style", ";",
                          "set", "-u", "-w", "-t", t, "pane-border-style"])
            tmuxThemed[t] = nil
        }
    }

    private var focusPending = false
    private var lastRaised: CGWindowID?
    @objc func focusChanged() {
        guard !focusPending else { return }
        focusPending = true
        DispatchQueue.main.async { [weak self] in
            self?.focusPending = false
            self?.applyFocus()
        }
    }

    private func applyFocus() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedWID: CGWindowID?
        if let front, observers[front] != nil, let el: AXUIElement = axAttr(AXUIElementCreateApplication(front), kAXFocusedWindowAttribute) {
            focusedWID = axWindowID(el)
        }
        self.focusedWID = focusedWID
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (wid, halo) in halos {
            halo.layers.setFocused(wid == focusedWID, reduceMotion: reduce)
            halo.badge.setFocused(wid == focusedWID, reduceMotion: reduce)
        }
        if let wid = focusedWID, wid != lastRaised, let halo = halos[wid] { halo.show(below: wid) } // it was just raised
        lastRaised = focusedWID
    }

    @objc func activated() {
        focusChanged()
        verifySoon()   // windows gone (desktop click, stage switch) or back (Stage Manager strip, another Space)
    }

    private func place(_ wid: CGWindowID, _ k: (session: Session, tty: String), frame f: CGRect) {
        guard let name = k.session.identity, let id = identities[name] else { return }
        let isNew = halos[wid] == nil
        let halo = halos[wid] ?? Halo()
        halos[wid] = halo
        ttyForWindow[wid] = k.tty
        halo.layers.configure(id, settings)
        let project = k.session.project.map { ($0 as NSString).lastPathComponent } ?? id.name
        halo.badge.configure(name: project, id)
        if !halo.moving { halo.setTarget(f) }
        halo.show(below: wid)
        if isNew { halo.appear() }
    }

    private func parked(_ wid: CGWindowID, _ f: CGRect) -> Bool {
        guard let el = elements[wid] else { return false }
        return isParked(cg: f.size, ax: axFrame(el))
    }

    /// A window in full screen gets no halo. On a notched display native full screen leaves the notch band
    /// out of the window frame, so the size test alone misses it: ask AX when the size doesn't match.
    private func isFullScreen(_ wid: CGWindowID, _ f: CGRect) -> Bool {
        if NSScreen.screens.contains(where: { abs($0.frame.width - f.width) < 2 && abs($0.frame.height - f.height) < 2 }) { return true }
        guard let el = elements[wid] else { return false }
        return axAttr(el, "AXFullScreen") ?? false
    }

    private func dropHalo(_ wid: CGWindowID) {
        settle[wid]?.cancel()
        settle[wid] = nil
        halos[wid]?.hide()
        halos[wid] = nil
    }

    /// Minimize: the halo leaves with the window and stays away until the window is restored.
    private func vanish(_ wid: CGWindowID) {
        dropHalo(wid)
        vanished[wid] = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.schedule() }
    }

    /// One window-server query: is every halo's window still on screen where the halo is drawn?
    /// Stage Manager, Show Desktop and Mission Control take windows away without any AX event.
    private func verify() {
        guard !halos.isEmpty || !known.isEmpty else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var frames: [CGWindowID: CGRect] = [:]
        for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard let n = w[kCGWindowNumber as String] as? CGWindowID, halos[n] != nil || known[n] != nil,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            frames[n] = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        for (wid, halo) in halos {
            guard let f = frames[wid] else { dropHalo(wid); continue } // rebuild brings it back once the window is on screen again
            let t = halo.target
            let resized = abs(f.width - t.width) > 1 || abs(f.height - t.height) > 1
            if resized && parked(wid, f) { dropHalo(wid); continue } // off to the Stage Manager strip
            if !halo.moving && (resized || abs(f.minX - t.minX) > 1 || abs(f.minY - t.minY) > 1) {
                halo.beginMove()
                settleLater(wid, halo)
            }
        }
        // back on screen (Stage Manager strip, another Space, restored): re-attach from what we already know
        var placed = false
        for (wid, k) in known where halos[wid] == nil && vanished[wid] == nil {
            guard let f = frames[wid], !isFullScreen(wid, f), !parked(wid, f) else { continue }
            place(wid, k, frame: f)
            placed = true
        }
        if placed { focusChanged() }
    }

    private func verifySoon() {
        for d in [0.05, 0.15, 0.25, 0.35, 0.8, 1.3] { // Stage Manager starts flying windows ~0.1 s in
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.verify() }
        }
    }

    /// Fade a moved halo back in once its window has stopped moving and the mouse is up.
    private func settleLater(_ wid: CGWindowID, _ halo: Halo) {
        settle[wid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.halos[wid] === halo else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.settleLater(wid, halo); return }
            self.settle[wid] = nil
            if let f = cgWindowFrame(wid), !self.isFullScreen(wid, f), !self.parked(wid, f) { halo.endMove(at: f) } else { self.dropHalo(wid) }
        }
        settle[wid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func keyDown(_ e: NSEvent) {
        guard let wid = focusedWID, let halo = halos[wid] else { return }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""                 // only to recognise shortcuts
        let tty = ttyForWindow[wid], id = halo.layers.identity
        if mods == .command && key == "m" { vanish(wid); return }                   // Cmd-M
        if mods == .command && key == "v" {                                         // paste: beamed in
            halo.layers.pasteFlow()
            if let tty, let id { markEffect(tty: tty, id: id, cursor: "#00ffff", duration: 0.7) }
            return
        }
        if mods == .control && key == "u" {                                         // Ctrl-U: struck out
            halo.layers.wipe()
            if let tty, let id { markEffect(tty: tty, id: id, cursor: "#ff00ff", duration: 0.34) }
            return
        }
        guard !mods.contains(.command), !mods.contains(.control) else { return }  // shortcuts aren't typing
        endMark()                                                                   // typing takes over at once
        if (e.keyCode == 36 || e.keyCode == 76) && mods.isEmpty {                   // Return sends the prompt
            halo.layers.explode()
            if let tty, let id { detonate(tty: tty, id: id) }
        } else {
            halo.layers.kick()
            if let tty, let id { drive(tty: tty, bg: id.bgHex) }
        }
    }

    /// Ghostty runs its shader only when it redraws (custom-shader-animation = false). For ~0.4s after a
    /// keystroke, re-send the background colour the window already has, 30 times a second: each one is
    /// a no-op that makes Ghostty draw the next frame of the typing impact. Idle terminals cost nothing.
    private func drive(tty: String, bg: String, duration: Double = 0.4, fast: Bool = false) {
        let now = CACurrentMediaTime()
        pump = (tty, bg, max(now + duration, pump?.tty == tty ? pump!.until : 0))
        if fast { fastUntil = max(fastUntil, now + duration) }
        startPump()
    }

    /// Paste (#00ffff) and Ctrl+U (#ff00ff) are signalled to halo-type.glsl by a marker cursor colour;
    /// the shader times them from the cursor move that follows. The colour comes back when they end,
    /// or at once if you keep typing.
    private func markEffect(tty: String, id: Identity, cursor marker: String, duration: Double) {
        if let m = mark, m.tty != tty { writeTTY(m.tty, "\u{1b}]12;\(m.cursor)\u{7}") }
        if let b = boom { boom = nil; if b.tty != tty { writeTTY(b.tty, "\u{1b}]12;\(b.cursor)\u{7}") } }
        writeTTY(tty, "\u{1b}]12;\(marker)\u{7}")
        mark = (tty, id.hex[0], CACurrentMediaTime() + duration)
        drive(tty: tty, bg: id.bgHex, duration: duration + 0.05, fast: true)
    }

    private func endMark() {
        guard let m = mark else { return }
        writeTTY(m.tty, "\u{1b}]12;\(m.cursor)\u{7}")
        mark = nil
    }

    /// Return: the in-terminal explosion. Its clock rides in the cursor colour: white-hot #ffffBB with BB
    /// counting down ff -> 00 over the blast (halo-type.glsl reads it), then the cursor gets its colour back.
    private func detonate(tty: String, id: Identity) {
        if let b = boom, b.tty != tty { writeTTY(b.tty, "\u{1b}]12;\(b.cursor)\u{7}") }
        if let m = mark, m.tty != tty { writeTTY(m.tty, "\u{1b}]12;\(m.cursor)\u{7}") }
        mark = nil
        boom = (tty, CACurrentMediaTime(), id.hex[0])
        startPump()
    }

    private func startPump() {
        guard pumpTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pumpTick() }
        RunLoop.main.add(t, forMode: .common)
        pumpTimer = t
    }

    private func pumpTick() {
        let now = CACurrentMediaTime()
        pumpFrame += 1
        if let m = mark, now >= m.until { endMark() }
        if let b = boom {
            let p = (now - b.start) / boomDuration
            if p < 1 {
                let v = Int(((1 - p) * 255).rounded())
                writeTTY(b.tty, "\u{1b}]12;#ffff\(v < 16 ? "0" : "")\(String(v, radix: 16))\u{7}")
                return
            }
            writeTTY(b.tty, "\u{1b}]12;\(b.cursor)\u{7}")
            boom = nil
        }
        if let p = pump, now < p.until {
            // 60 fps for the short paste / erase effects, 30 fps is plenty for the typing light
            if now < fastUntil || pumpFrame % 2 == 0 { writeTTY(p.tty, "\u{1b}]11;\(p.bg)\u{7}") }
            return
        }
        pump = nil
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    /// Mouse pressed on a Claude window: the moment it starts moving/resizing the halo vanishes and comes
    /// back in place on release; a release on the minimize / close / zoom button takes it away at once.
    /// A click anywhere else (desktop with Stage Manager, another app) triggers a visibility check.
    private func mouseDown() {
        guard let wid = windowUnderMouse(), let halo = halos[wid] else { verifySoon(); return }
        let start = cgWindowFrame(wid)
        let buttons = start.map { f in (buttonOffsets[wid] ?? []).map { $0.offsetBy(dx: f.minX, dy: f.maxY) } } ?? []
        let pressedOnButton = buttons.contains { $0.contains(NSEvent.mouseLocation) }
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let frame = cgWindowFrame(wid), frame != start, self.halos[wid] === halo, !halo.moving {
                halo.beginMove()
                self.settleLater(wid, halo)
            }
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            self.dragTimer = nil
            if pressedOnButton && buttons.contains(where: { $0.contains(NSEvent.mouseLocation) }) { self.vanish(wid) }
            self.verifySoon() // safety net: whatever the click did, a window that left the screen loses its halo
        }
    }

    private func watchExits(_ sessions: [Session]) {
        let pids = Set(sessions.map { $0.pid })
        for (pid, src) in exitSources where !pids.contains(pid) { src.cancel(); exitSources[pid] = nil }
        for pid in pids where exitSources[pid] == nil {
            let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            src.setEventHandler { [weak self] in self?.schedule() }
            src.resume()
            exitSources[pid] = src
        }
    }
}

let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification as String)
}

/// Frontmost normal window under the mouse, ignoring Halo's own overlays.
func windowUnderMouse() -> CGWindowID? {
    let loc = NSEvent.mouseLocation
    let p = CGPoint(x: loc.x, y: (NSScreen.screens.first?.frame.height ?? 0) - loc.y)
    let me = ProcessInfo.processInfo.processIdentifier
    for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
        guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != me,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
        if r.contains(p) { return w[kCGWindowNumber as String] as? CGWindowID }
    }
    return nil
}

/// Live window frame from the window server (Cocoa coordinates), cheap enough to read every frame.
func cgWindowFrame(_ wid: CGWindowID) -> CGRect? {
    let ids = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    defer { ids.deallocate() }
    ids[0] = UnsafeRawPointer(bitPattern: UInt(wid))
    guard let arr = CFArrayCreate(nil, ids, 1, nil),
          let info = (CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]])?.first,
          let b = info[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

let boomDuration = 1.1 // keep in sync with BOOM in ~/.config/ghostty/shaders/halo-type.glsl

func writeTTY(_ path: String, _ s: String) {
    guard path.hasPrefix("/dev/tty") else { return }
    let fd = open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { return }
    s.withCString { _ = write(fd, $0, strlen($0)) }
    close(fd)
}

// MARK: - Preview: render every identity to a contact sheet

func renderPreview(to out: String, time: Double, kick: Bool = false, focusIn: Bool = false) {
    guard let cfg = loadConfig() else { print("no config at \(configPath)"); exit(1) }
    let win = CGSize(width: 460, height: 290)
    let cols = 3
    let tileW = win.width + 2 * (cfg.settings.glow + 10), tileH = win.height + 2 * (cfg.settings.glow + 10) + 26
    let rows = (cfg.order.count + cols - 1) / cols
    let sheet = CGSize(width: CGFloat(cols) * tileW + 40, height: CGFloat(rows) * tileH + 40)
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: sheet)
    root.backgroundColor = cgColor("#0c0c12")
    let mono = NSFont(name: "JetBrainsMono Nerd Font", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    let sample: [(String, String)] = [
        ("❯ claude", "#f0f0ff"), ("", "#f0f0ff"),
        ("⏺ Reading src/app.tsx", "#c8c8e0"), ("  export function App() {", "#9aa4ff"),
        ("    return <Cockpit theme=\"halo\" />", "#7dffb3"), ("  }", "#9aa4ff"), ("", "#f0f0ff"),
        ("✻ Shipping… (12s · ↓ 3.1k tokens)", "#ffb347"),
    ]
    for (i, name) in cfg.order.enumerated() {
        guard let id = cfg.identities[name] else { continue }
        let col = i % cols, row = i / cols
        let origin = CGPoint(x: 20 + CGFloat(col) * tileW, y: sheet.height - 20 - CGFloat(row + 1) * tileH)
        let tile = CALayer()
        tile.frame = CGRect(origin: origin, size: CGSize(width: tileW, height: tileH))
        root.addSublayer(tile)
        let L = HaloLayers()
        L.configure(id, cfg.settings)
        let size = CGSize(width: tileW, height: tileH - 26)
        L.setSize(size, scale: 2)
        L.setFocused(true, reduceMotion: false)
        if kick { L.explode() }
        if focusIn { L.setFocused(false, reduceMotion: false); L.setFocused(true, reduceMotion: false) }
        L.root.frame = CGRect(origin: CGPoint(x: 0, y: 26), size: size)
        tile.addSublayer(L.root)
        // stand-in for the terminal window: its translucent background over the aurora, plus some text
        let edge = CGRect(origin: .zero, size: size).insetBy(dx: L.pad, dy: L.pad)
        let term = CALayer()
        term.frame = edge.offsetBy(dx: 0, dy: 26)
        term.cornerRadius = cfg.settings.cornerRadius
        term.cornerCurve = .continuous
        term.backgroundColor = cgColor(id.bgHex, alpha: 0.66) // Ghostty background-opacity
        tile.addSublayer(term)
        for (k, (line, hex)) in sample.enumerated() {
            let t = CATextLayer()
            t.contentsScale = 2
            t.string = NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: NSColor(cgColor: cgColor(hex)!)!])
            t.frame = CGRect(x: 16, y: edge.height - 30 - CGFloat(k) * 17, width: edge.width - 32, height: 16)
            term.addSublayer(t)
        }
        // the session badge, top-right in the title bar area (its root sits in a stand-in window frame)
        let badge = Badge()
        badge.configure(name: ["my-app", "api", "halo", "docs"][i % 4], id)
        badge.setFocused(true, reduceMotion: false)
        badge.root.removeFromSuperlayer()
        let bs = badge.root.bounds.size
        badge.root.frame = CGRect(x: term.frame.maxX - bs.width + Badge.margin - 10, y: term.frame.maxY - 14 - bs.height / 2,
                                  width: bs.width, height: bs.height)
        tile.addSublayer(badge.root)
        let label = CATextLayer()
        label.contentsScale = 2
        label.string = NSAttributedString(string: "\(name)  ·  \(id.style.rawValue)",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(cgColor: id.colors[0])!])
        label.frame = CGRect(x: L.pad, y: 2, width: tileW - 2 * L.pad, height: 18)
        tile.addSublayer(label)
    }
    let scale: CGFloat = 2
    let w = Int(sheet.width * scale), h = Int(sheet.height * scale)
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { exit(1) }
    // Render at 2x: wrap the sheet in a pixel-sized layer, scaled from its bottom-left corner.
    let canvas = CALayer()
    canvas.frame = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
    root.anchorPoint = .zero
    root.position = .zero
    root.transform = CATransform3DMakeScale(scale, scale, 1)
    canvas.addSublayer(root)
    guard let queue = device.makeCommandQueue() else { exit(1) }
    let renderer = CARenderer(mtlTexture: tex, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         kCARendererMetalCommandQueue: queue])
    renderer.layer = canvas
    renderer.bounds = canvas.frame
    CATransaction.flush()
    let t0 = CACurrentMediaTime() + time
    renderer.beginFrame(atTime: t0, timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    // CARenderer encodes into `queue`; an empty buffer committed after it completes once the frame has.
    let fence = queue.makeCommandBuffer()!
    fence.commit()
    fence.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // Metal textures start at the top-left; flip the rows back.
    let flipped = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    flipped.translateBy(x: 0, y: CGFloat(h))
    flipped.scaleBy(x: 1, y: -1)
    flipped.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
    let image = flipped.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(cfg.order.count) identities, t=\(time)s)")
}

// MARK: - Main

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--preview" {
    renderPreview(to: args[2], time: args.count >= 4 ? Double(args[3]) ?? 3 : 3, kick: args.contains("--boom"), focusIn: args.contains("--focus"))
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
