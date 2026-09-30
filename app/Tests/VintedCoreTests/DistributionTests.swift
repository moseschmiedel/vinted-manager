import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import VintedCore

@Test func locatingOutsideAnyLibraryStopsAtFilesystemRoot() {
    #expect(VintedRepository.locate(from: URL(fileURLWithPath: "/Applications/")) == nil)
}

@Test(.timeLimit(.minutes(1))) func cliDrainsLargeOutputOnBothPipes() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vinted-pipes-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let script = root.appendingPathComponent("vinted")
    try """
    #!/bin/sh
    /bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null
    /bin/dd if=/dev/zero bs=65536 count=4 1>&2 2>/dev/null
    """.write(to: script, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let output = try await VintedCLI(repository: VintedRepository(root: root)).run([])
    #expect(output.utf8.count == 262144)
}

@Test func createsLibraryWithoutCopyingSourceOrPersonalItems() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vinted-library-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await VintedCLI.createLibrary(at: root)
    #expect(VintedRepository.isRepository(root))
    #expect(try repository.loadItems().isEmpty)
    #expect(repository.inboxGroups().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cli").path))
    #expect(VintedCLI.environment(repository: repository)["VINTED_REPO"] == root.path)
    // The portable launcher works from an unrelated working directory without cargo.
    let process = Process()
    process.executableURL = repository.cli
    process.arguments = ["index"]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func nativeConverterAppliesOrientationResizesAndRemovesPrivateMetadata() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vinted-photo-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.jpg")
    let outputURL = root.appendingPathComponent("output.jpg")
    let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private camera note"],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = package.appendingPathComponent(".build/debug/VintedPhotoConverter")
    process.arguments = [sourceURL.path, outputURL.path, "40"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let output = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifUserComment] == nil)
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
}
