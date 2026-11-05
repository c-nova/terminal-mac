import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TerminalMacCore
import TerminalUI

final class CoreTests: XCTestCase {
    func testSigningTrustLoadsPinnedFingerprintFromPackagedResources() throws {
        let app = try signingFixture()
        let bundle = try XCTUnwrap(Bundle(url: app))
        if let configured = try? SigningTrust.pinnedFingerprint() {
            XCTAssertEqual(try SigningTrust.pinnedFingerprint(in: bundle), configured)
        } else {
            XCTAssertThrowsError(try SigningTrust.pinnedFingerprint(in: bundle))
        }
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/terminal-mac_TerminalMacCore.bundle"))
        XCTAssertThrowsError(try SigningTrust.pinnedFingerprint(in: bundle))
    }

    func testSigningTrustRejectsUnsignedAndAdHocApps() throws {
        let app = try signingFixture()
        try codesign(["--remove-signature", app.path])
        XCTAssertThrowsError(try SigningTrust.verify(app, identifier: "dev.terminal-mac.guest"))
        try codesign(["--force", "--sign", "-", "--timestamp=none", app.path])
        XCTAssertThrowsError(try SigningTrust.verify(app, identifier: "dev.terminal-mac.guest"))
        XCTAssertThrowsError(try SigningTrust.verify(app, identifier: "invalid\" or true"))
    }

    func testSigningTrustAcceptsPinnedSignerAndRejectsTampering() throws {
        guard let identity = ProcessInfo.processInfo.environment["TERMINAL_MAC_TEST_SIGNING_IDENTITY"], !identity.isEmpty else {
            throw XCTSkip("Set TERMINAL_MAC_TEST_SIGNING_IDENTITY to test the pinned private key locally")
        }
        let app = try signingFixture()
        try codesign(["--force", "--sign", identity, "--timestamp=none", app.path])
        XCTAssertNoThrow(try SigningTrust.verify(app, identifier: "dev.terminal-mac.guest"))
        XCTAssertThrowsError(try SigningTrust.verify(app, identifier: "dev.terminal-mac.host"))
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/payload.txt"))
        XCTAssertThrowsError(try SigningTrust.verify(app, identifier: "dev.terminal-mac.guest"))
    }

    func signingFixture() throws -> URL {
        let app = try temporary().appendingPathComponent("Guest.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle.module.bundleURL, to: contents.appendingPathComponent("Resources/terminal-mac_TerminalMacCore.bundle"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/fixture").path)
        let plist = ["CFBundleIdentifier": "dev.terminal-mac.guest", "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("original".utf8).write(to: contents.appendingPathComponent("Resources/payload.txt"))
        return app
    }

    func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("codesign fixture failed (\(process.terminationStatus))") }
    }

    func testGuestPixelsDecodeFoundationLZ4WithBoundedOutput() throws {
        for (width, height, stride) in [(2, 2, 8), (2, 2, 12), (256, 128, 1024)] {
            let original = Data((0..<(height * stride)).map { UInt8($0 % 251) })
            let compressed = try (original as NSData).compressed(using: .lz4) as Data
            XCTAssertEqual(try GuestImage.pixels(compressed, width: width, height: height, bytesPerRow: stride), original)
            XCTAssertThrowsError(try GuestImage.pixels(Data(compressed.dropLast()), width: width, height: height, bytesPerRow: stride))
            XCTAssertThrowsError(try GuestImage.pixels(compressed + Data([0]), width: width, height: height, bytesPerRow: stride))
        }
    }

    func testGuestPixelsRejectBombsLengthMismatchesAndInvalidDimensions() throws {
        let original = Data(repeating: 0, count: 8 * 1024 * 1024)
        let bomb = try (original as NSData).compressed(using: .lz4) as Data
        XCTAssertThrowsError(try GuestImage.pixels(bomb, width: 1, height: 1, bytesPerRow: 4))
        let short = try (Data(repeating: 0, count: 4) as NSData).compressed(using: .lz4) as Data
        XCTAssertThrowsError(try GuestImage.pixels(short, width: 2, height: 2, bytesPerRow: 8))
        XCTAssertThrowsError(try GuestImage.pixels(Data(), width: 1, height: 1, bytesPerRow: 4))
        XCTAssertThrowsError(try GuestImage.pixels(Data([1, 2, 3]), width: 1, height: 1, bytesPerRow: 4))
        for (width, height, stride) in [(0, 1, 4), (-1, 1, 4), (Int.max, 1, 4), (1, Int.max, 4),
                                      (8192, 8192, 32768), (1, 1, Int.max), (2, 2, 7)] {
            XCTAssertThrowsError(try GuestImage.pixelByteCount(width: width, height: height, bytesPerRow: stride))
        }
        XCTAssertNoThrow(try GuestImage.pixelByteCount(width: 7680, height: 4320, bytesPerRow: 30720))
    }

    func testGuestPNGValidatesFormatAndDimensionsBeforeDecoding() throws {
        func png(width: Int, height: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let valid = try png(width: 32, height: 16)
        let decoded = try GuestImage.png(valid)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 16)
        XCTAssertThrowsError(try GuestImage.pngSource(png(width: 8193, height: 1)))
        XCTAssertThrowsError(try GuestImage.png(Data()))
        XCTAssertThrowsError(try GuestImage.png(Data("not an image".utf8)))
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        XCTAssertThrowsError(try GuestImage.pngSource(gif))
    }

    func testTerminalTextRemovesControlSequencesAndPreservesUnicode() {
        let payload = "\u{1b}]52;c;VEVTVA==\u{7}\u{9b}31m\r\n\t\0\u{7f}"
        let safe = terminalText(payload)
        XCTAssertFalse(safe.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) })
        XCTAssertEqual(terminalText("hello 🌍 日本語"), "hello 🌍 日本語")
        XCTAssertEqual(terminalText("first\nsecond\r", allowNewlines: true), "first\nsecond ")
        XCTAssertEqual(terminalText("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(Span(payload).text, safe)
        XCTAssertEqual([Span(payload)].rendered, safe)
        var changed = Span("initial")
        changed.text = payload
        XCTAssertEqual([changed].rendered, safe)
        XCTAssertEqual([Span(payload, "\u{1b}[31m")].rendered, "\u{1b}[31m" + safe + Theme.reset)
        XCTAssertFalse(Box.line(column: 1, row: 1, width: 80, [Span(payload)]).contains("\u{1b}]52;"))
    }

    func testJSONIntegerRejectsInvalidNumbersWithoutTrapping() throws {
        for input in [NSNumber(value: 1e100), NSNumber(value: -1e100), NSNumber(value: Double.nan),
                      NSNumber(value: Double.infinity), NSNumber(value: 1.5), NSNumber(value: true)] {
            XCTAssertThrowsError(try jsonInteger(input, range: Int.min...Int.max))
        }
        XCTAssertThrowsError(try jsonInteger(nil, range: 0...16383))
        XCTAssertThrowsError(try jsonInteger("1", range: 0...16383))
        XCTAssertThrowsError(try jsonInteger(-1, range: 0...16383))
        XCTAssertThrowsError(try jsonInteger(16384, range: 0...16383))
        XCTAssertThrowsError(try jsonInteger(1001, range: -1000...1000))
        XCTAssertEqual(try jsonInteger(0, range: 0...16383), 0)
        XCTAssertEqual(try jsonInteger(NSNumber(value: 42.0), range: 0...16383), 42)
        XCTAssertEqual(try jsonInteger(-1000, range: -1000...1000), -1000)
        XCTAssertEqual(try jsonInteger(NSNumber(value: Int.max), range: Int.min...Int.max), Int.max)
    }

    func testFirstRunPlansSkipDownloadAndInstallForExistingMacs() {
        let machine = Machine(name: "work", cpu: 4, memoryGiB: 4, diskGiB: 64, installed: true)
        XCTAssertEqual(SetupPlan(name: "work", machine: machine, hasLocalImage: false).steps,
                       ["start-or-resume-vm", "check-guest-helper-and-permissions", "open-terminal-view-if-supported"])
        XCTAssertEqual(SetupPlan(name: "work", machine: nil, hasLocalImage: true).steps.first, "install-macos")
        XCTAssertEqual(SetupPlan(name: "work", machine: nil, hasLocalImage: false).steps.first, "download-or-reuse-apple-restore-image")
        var partial = machine; partial.installed = false
        XCTAssertTrue(SetupPlan(name: "work", machine: partial, hasLocalImage: true).steps.contains("retry-incomplete-installation"))
    }
    func testGuestReadinessRequiresBothPermissions() {
        XCTAssertEqual(GuestReadiness(nil), .unavailable)
        XCTAssertEqual(GuestReadiness([:]), .permissions)
        XCTAssertEqual(GuestReadiness(["screenRecording": "true", "accessibility": "false"]), .permissions)
        XCTAssertEqual(GuestReadiness(["screenRecording": "false", "accessibility": "true"]), .permissions)
        XCTAssertEqual(GuestReadiness(["screenRecording": "true", "accessibility": "true"]), .ready)
    }
    func testSetupLockPreventsConcurrentInstallAndReleases() throws {
        let path = try temporary().appendingPathComponent("setup.lock")
        var first: FileLock? = try FileLock(path)
        try withExtendedLifetime(first) { XCTAssertThrowsError(try FileLock(path)) }
        first = nil
        XCTAssertNoThrow(try FileLock(path))
    }
    func testSetupLockRejectsSymlink() throws {
        let root = try temporary()
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        let link = root.appendingPathComponent("setup.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FileLock(link))
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testMachineNamesCannotEscapeStore() throws {
        for name in ["../host", "/tmp", "", ".", "a/b", "a b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try validateName(name))
        }
        for name in ["default", "agent-1", "mac_test", "M2"] { XCTAssertNoThrow(try validateName(name)) }
    }
    func testParserRejectsUnknownDuplicateAndMissingOptions() throws {
        XCTAssertThrowsError(try Arguments(["--force"], flags: ["offline"]))
        XCTAssertThrowsError(try Arguments(["--disk"], options: ["disk"]))
        XCTAssertThrowsError(try Arguments(["--disk", "4", "--disk", "8"], options: ["disk"]))
        XCTAssertThrowsError(try Arguments(["--disk", "0"], options: ["disk"]).integer("disk", default: 64, range: 32...1024))
        XCTAssertEqual(try Arguments(["--", "--literal"]).positionals, ["--literal"])
    }
    func testMailboxRejectsTraversalSymlinksHardlinksAndOversizedFiles() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let secret = root.appendingPathComponent("secret")
        try Data("host file".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: secret.path)
        XCTAssertThrowsError(try mailbox.read("link"))
        XCTAssertThrowsError(try mailbox.read("../secret"))
        XCTAssertThrowsError(try mailbox.write(Data(), named: "../escape"))
        XCTAssertThrowsError(try mailbox.read("secret", limit: 1))
        XCTAssertEqual(link(secret.path, root.appendingPathComponent("hardlink").path), 0)
        XCTAssertThrowsError(try mailbox.read("hardlink"))
    }
    func testPublishingReplacesSymlinkInsteadOfWritingItsTarget() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("reply.json").path, withDestinationPath: target.path)
        try mailbox.write(Data("reply".utf8), named: "reply.json")
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
        XCTAssertEqual(try mailbox.read("reply.json"), Data("reply".utf8))
    }
    func testMailboxRejectsDirectorySymlinkAndNonregularFile() throws {
        let parent = try temporary()
        let actual = parent.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try Mailbox(alias))
        let mailbox = try Mailbox(actual)
        XCTAssertEqual(mkfifo(actual.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try mailbox.read("pipe"))
    }
    func testExpiredAndMismatchedRequestsAreDiscarded() throws {
        let root = try temporary()
        let mailbox = try Mailbox(root)
        let expired = Request(action: "click", timeout: -1)
        try mailbox.write(JSONEncoder().encode(expired), named: "request-\(expired.id.uuidString).json")
        let valid = Request(action: "status")
        try mailbox.write(JSONEncoder().encode(valid), named: "request-\(UUID().uuidString).json")
        XCTAssertTrue(try mailbox.requests().isEmpty)
    }
    func testRequestReplyRoundTripAndCleanup() async throws {
        let root = try temporary()
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "type", arguments: ["text": "hello 🌍"], timeout: 2)
        let task = Task { try await client.call(request) }
        var received: Request?
        for _ in 0..<50 {
            received = try server.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(received?.arguments["text"], "hello 🌍")
        try server.respond(Reply(id: request.id, values: ["done": "true"]))
        let reply = try await task.value
        XCTAssertEqual(reply.values["done"], "true")
        XCTAssertNil(try client.read("request-\(request.id.uuidString).json"))
        XCTAssertNil(try client.read("reply-\(request.id.uuidString).json"))
    }
    func testMailboxTimeoutCleansPendingAction() async throws {
        let mailbox = try Mailbox(temporary())
        let request = Request(action: "click", timeout: 0.05)
        do { _ = try await mailbox.call(request); XCTFail("Expected timeout") } catch {}
        XCTAssertNil(try mailbox.read("request-\(request.id.uuidString).json"))
    }
    func testInputHandlesFragmentedUnicodeArrowsMouseAndExit() {
        var parser = TerminalInput()
        let emoji = Array("🌍".utf8)
        XCTAssertEqual(parser.feed(Array(emoji.prefix(2))), [])
        XCTAssertEqual(parser.feed(Array(emoji.dropFirst(2))), [.text("🌍")])
        XCTAssertEqual(parser.feed([27, 91]), [])
        XCTAssertEqual(parser.feed([65]), [.key("up")])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;12;8M".utf8)), [.mouse(button: 0, column: 12, row: 8, released: false)])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;12;8m".utf8)), [.mouse(button: 0, column: 12, row: 8, released: true)])
        XCTAssertEqual(parser.feed([3, 29]), [.key("ctrl+c"), .quit])
    }
    func testEscapeAndUnknownSequencesDoNotBecomeGuestText() {
        var parser = TerminalInput()
        XCTAssertEqual(parser.feed([27]), [])
        XCTAssertEqual(parser.feed([], flushEscape: true), [.key("escape")])
        XCTAssertEqual(parser.feed(Array("\u{1b}[99~".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\u{1b}[<0;0;0M".utf8)), [])
        XCTAssertEqual(parser.feed([255, 65]), [.text("A")])
    }
}
