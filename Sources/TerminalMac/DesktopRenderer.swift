import CoreGraphics
import CPhoneShim
import Darwin
import Foundation
import ImageIO
import TerminalMacCore
import TerminalUI
import UniformTypeIdentifiers

enum DesktopTransport: String {
    /// Raw pixels in POSIX shared memory: no encoding, no base64, nothing through the pty.
    case kittySharedMemory = "shared memory"
    /// PNG chunks through the pty, for kitty-protocol terminals without shared memory.
    case kittyDirect = "kitty png"
    case iterm = "iTerm2 png"
}

/// A guest frame as it arrives from the mailbox. Decoding happens on the render queue.
enum DesktopFrame {
    /// lz4-compressed BGRA rows from the live stream.
    case pixels(Data, width: Int, height: Int, bytesPerRow: Int)
    /// A PNG from a guest helper that predates the live stream.
    case encoded(Data)
}

/// Where the desktop sits: a canvas covering whole cells, with the image drawn from its top-left
/// at exactly `imageWidth`×`imageHeight` device pixels so the terminal never resamples it.
struct DesktopPlacement: Equatable {
    let column: Int, row: Int, columns: Int, rows: Int
    let canvasWidth: Int, canvasHeight: Int
    let imageWidth: Int, imageHeight: Int
    /// Opaque fill for transports without alpha. Kitty gets transparent corners.
    let background: UInt32?
}

/// Turns guest frames into terminal graphics on a background queue. Only the newest frame is
/// kept: if the terminal falls behind, stale frames are dropped rather than queued.
final class DesktopRenderer: @unchecked Sendable {
    struct Stats { var frames = 0; var milliseconds = 0.0; var sourceWidth = 0; var sourceHeight = 0 }
    private let queue = DispatchQueue(label: "terminal-mac.render", qos: .userInteractive)
    private let writer: TerminalWriter
    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pending: DesktopFrame?, force = false, busy = false, held = false
    private var placement: DesktopPlacement?
    private var transport: DesktopTransport
    private var stats = Stats()
    // Only touched on `queue`.
    private var imageID = 0, sequence = 0
    private var last: CGImage?

    init(writer: TerminalWriter, transport: DesktopTransport) { self.writer = writer; self.transport = transport }

    var currentStats: Stats { lock.withLock { stats } }
    var currentTransport: DesktopTransport { lock.withLock { transport } }
    func configure(placement: DesktopPlacement?, transport: DesktopTransport? = nil) {
        lock.withLock { self.placement = placement; if let transport { self.transport = transport } }
    }
    /// While held, frames are kept but not drawn. iTerm2 images cover text, so overlays hold it.
    func hold(_ value: Bool) {
        lock.withLock { held = value }
        if !value { redraw() }
    }
    /// Safe to call from any thread.
    func submit(_ frame: DesktopFrame) { schedule { self.pending = frame } }
    /// Draws the last frame again, for example after a resize or screen clear.
    func redraw() { schedule { self.force = true } }
    /// Removes both double-buffered images. Call before leaving the alternate screen.
    func clear() -> String {
        queue.sync {}
        return currentTransport == .iterm ? "" : "\u{1b}_Ga=d,d=I,i=2,q=2;\u{1b}\\\u{1b}_Ga=d,d=I,i=3,q=2;\u{1b}\\"
    }

    private func schedule(_ change: @escaping () -> Void) {
        let start = lock.withLock { () -> Bool in
            change()
            if busy { return false }
            busy = true; return true
        }
        if start { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            let next = lock.withLock { () -> (DesktopFrame?, DesktopPlacement?, DesktopTransport, Bool)? in
                guard pending != nil || force else { busy = false; return nil }
                defer { pending = nil; force = false }
                return (pending, held ? nil : placement, transport, force)
            }
            guard let (frame, placement, transport, _) = next else { return }
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                if let frame { last = decode(frame) ?? last }
                guard let placement, let image = last, let escape = encode(image, placement: placement, transport: transport) else { return }
                writer.writeAndWait("\u{1b}[\(placement.row);\(placement.column)H" + escape)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                lock.withLock {
                    stats.frames += 1; stats.sourceWidth = image.width; stats.sourceHeight = image.height
                    stats.milliseconds = stats.milliseconds == 0 ? elapsed : stats.milliseconds * 0.8 + elapsed * 0.2
                }
            }
        }
    }

    private func decode(_ frame: DesktopFrame) -> CGImage? {
        switch frame {
        case .pixels(let compressed, let width, let height, let bytesPerRow):
            guard let pixels = try? GuestImage.pixels(compressed, width: width, height: height, bytesPerRow: bytesPerRow),
                  let provider = CGDataProvider(data: pixels as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .encoded(let data):
            return try? GuestImage.png(data)
        }
    }

    private func context(_ placement: DesktopPlacement, data: UnsafeMutableRawPointer?) -> CGContext? {
        let context = CGContext(data: data, width: placement.canvasWidth, height: placement.canvasHeight, bitsPerComponent: 8,
                                bytesPerRow: placement.canvasWidth * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        context?.interpolationQuality = .high
        return context
    }
    /// The desktop with softly rounded corners, like a display, anchored to the canvas top-left.
    private func compose(_ image: CGImage, placement p: DesktopPlacement, into context: CGContext) {
        let canvas = CGRect(x: 0, y: 0, width: p.canvasWidth, height: p.canvasHeight)
        if let background = p.background {
            context.setFillColor(CGColor(srgbRed: Double(background >> 16 & 255) / 255, green: Double(background >> 8 & 255) / 255, blue: Double(background & 255) / 255, alpha: 1))
            context.fill(canvas)
        } else { context.clear(canvas) }
        let target = CGRect(x: 0, y: p.canvasHeight - p.imageHeight, width: p.imageWidth, height: p.imageHeight)
        let radius = min(Double(p.imageWidth), Double(p.imageHeight)) * 0.012
        context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.clip()
        context.draw(image, in: target)
    }

    private func encode(_ image: CGImage, placement: DesktopPlacement, transport: DesktopTransport) -> String? {
        // The image sits below cell backgrounds, so menus drawn with a background stay on top.
        let box = "c=\(placement.columns),r=\(placement.rows),z=-1073741825"
        let next = imageID == 2 ? 3 : 2
        let replace = imageID == 0 ? "" : "\u{1b}_Ga=d,d=I,i=\(imageID),q=2;\u{1b}\\"
        switch transport {
        case .kittySharedMemory:
            sequence += 1
            let name = "/tmac.\(getpid()).\(sequence)", size = placement.canvasWidth * placement.canvasHeight * 4
            let fd = tp_shm_create(name, size)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), memory != MAP_FAILED else { tp_shm_unlink(name); return nil }
            defer { munmap(memory, size) }
            guard let context = context(placement, data: memory) else { tp_shm_unlink(name); return nil }
            compose(image, placement: placement, into: context)
            imageID = next
            // The terminal reads and unlinks the object.
            return "\u{1b}_Ga=T,f=32,t=s,s=\(placement.canvasWidth),v=\(placement.canvasHeight),S=\(size),i=\(next),q=2,C=1,\(box);\(Data(name.utf8).base64EncodedString())\u{1b}\\" + replace
        case .kittyDirect:
            guard let png = png(image, placement: placement) else { return nil }
            let bytes = Array(png.base64EncodedString().utf8)
            var output = "", offset = 0
            while offset < bytes.count {
                let end = min(offset + 4096, bytes.count)
                let header = offset == 0 ? "a=T,f=100,i=\(next),q=2,C=1,\(box)," : ""
                output += "\u{1b}_G\(header)m=\(end < bytes.count ? 1 : 0);\(String(decoding: bytes[offset..<end], as: UTF8.self))\u{1b}\\"
                offset = end
            }
            imageID = next
            return output + replace
        case .iterm:
            // PNG rather than JPEG: desktop text stays crisp. Frames only arrive when the screen changes.
            guard let png = png(image, placement: placement) else { return nil }
            return "\u{1b}]1337;File=inline=1;width=\(placement.columns);height=\(placement.rows);preserveAspectRatio=0:\(png.base64EncodedString())\u{7}"
        }
    }

    private func png(_ image: CGImage, placement: DesktopPlacement) -> Data? {
        guard let context = context(placement, data: nil) else { return nil }
        compose(image, placement: placement, into: context)
        guard let composed = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Asks the terminal whether it can read shared memory. The reply arrives on stdin as
    /// `ESC _ G i=31;OK ESC \`. Returns the escape to send and a cleanup for the probe object.
    static func sharedMemoryProbe() -> (query: String, cleanup: () -> Void)? {
        let name = "/tmac.\(getpid()).probe"
        let fd = tp_shm_create(name, 4)
        guard fd >= 0 else { return nil }
        let pixel: [UInt8] = [0, 0, 0, 255]
        _ = pixel.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, 4) }
        close(fd)
        return ("\u{1b}_Gi=31,s=1,v=1,a=q,t=s,f=32,S=4;\(Data(name.utf8).base64EncodedString())\u{1b}\\", { _ = tp_shm_unlink(name) })
    }
}
