#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct IconOutput {
    let path: String
    let pixels: Int
}

private let outputs: [IconOutput] = [
    .init(path: "apps/WristRemote/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", pixels: 1024),
    .init(path: "apps/WristRemote/Watch/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", pixels: 1024),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png", pixels: 16),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-16@2x.png", pixels: 32),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png", pixels: 32),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-32@2x.png", pixels: 64),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png", pixels: 128),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png", pixels: 256),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png", pixels: 256),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-256@2x.png", pixels: 512),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png", pixels: 512),
    .init(path: "apps/WristRemoteBridge/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png", pixels: 1024),
]

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(deviceRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

private func fill(_ path: NSBezierPath, with color: NSColor) {
    color.setFill()
    path.fill()
}

private func circle(center: CGPoint, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(
        ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    )
}

private func triangle(_ points: [CGPoint]) -> NSBezierPath {
    precondition(points.count == 3)
    let path = NSBezierPath()
    path.move(to: points[0])
    path.line(to: points[1])
    path.line(to: points[2])
    path.close()
    return path
}

private func removePNGMetadata(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.starts(with: signature) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    var output = Data(signature)
    var offset = signature.count
    var sawEnd = false
    let retainedChunks = Set(["IHDR", "sRGB", "IDAT", "IEND"])

    while offset + 12 <= bytes.count {
        let length =
            Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
        let end = offset + 12 + length
        guard end <= bytes.count,
              let type = String(
                  bytes: bytes[(offset + 4)..<(offset + 8)],
                  encoding: .ascii
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if retainedChunks.contains(type) {
            output.append(contentsOf: bytes[offset..<end])
        } else if type != "eXIf" {
            throw CocoaError(.fileReadUnknown)
        }

        offset = end
        if type == "IEND" {
            sawEnd = true
            break
        }
    }

    guard sawEnd, offset == bytes.count else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return output
}

private func drawIcon(size: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = graphicsContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = NSGradient(
        starting: color(5, 10, 25),
        ending: color(11, 20, 48)
    )!
    background.draw(in: canvas, angle: 90)

    let outerGlow = NSBezierPath(
        roundedRect: CGRect(x: 262, y: 122, width: 378, height: 780),
        xRadius: 189,
        yRadius: 189
    )
    fill(outerGlow, with: color(18, 50, 115))

    let remote = NSBezierPath(
        roundedRect: CGRect(x: 286, y: 146, width: 330, height: 732),
        xRadius: 165,
        yRadius: 165
    )
    let remoteGradient = NSGradient(
        starting: color(22, 72, 255),
        ending: color(0, 190, 255)
    )!
    remoteGradient.draw(in: remote, angle: 90)

    let signalColor = color(42, 143, 255)
    for (radius, width) in [(228.0, 34.0), (315.0, 30.0)] {
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: CGPoint(x: 512, y: 512),
            radius: radius,
            startAngle: -58,
            endAngle: 58
        )
        arc.lineWidth = width
        arc.lineCapStyle = .round
        signalColor.setStroke()
        arc.stroke()
    }

    let padCenter = CGPoint(x: 451, y: 556)
    fill(circle(center: padCenter, radius: 128), with: color(7, 15, 35))
    fill(circle(center: padCenter, radius: 52), with: color(19, 105, 255))

    let white = color(245, 249, 255)
    fill(triangle([
        CGPoint(x: 451, y: 652),
        CGPoint(x: 425, y: 618),
        CGPoint(x: 477, y: 618),
    ]), with: white)
    fill(triangle([
        CGPoint(x: 451, y: 460),
        CGPoint(x: 425, y: 494),
        CGPoint(x: 477, y: 494),
    ]), with: white)
    fill(triangle([
        CGPoint(x: 355, y: 556),
        CGPoint(x: 389, y: 530),
        CGPoint(x: 389, y: 582),
    ]), with: white)
    fill(triangle([
        CGPoint(x: 547, y: 556),
        CGPoint(x: 513, y: 530),
        CGPoint(x: 513, y: 582),
    ]), with: white)

    fill(circle(center: CGPoint(x: 451, y: 770), radius: 18), with: white)
    fill(circle(center: CGPoint(x: 451, y: 356), radius: 22), with: white)
    fill(circle(center: CGPoint(x: 451, y: 278), radius: 22), with: white)
    fill(circle(center: CGPoint(x: 451, y: 200), radius: 22), with: white)

    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        encoded,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return try removePNGMetadata(encoded as Data)
}

private let fileManager = FileManager.default
private let repositoryRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
guard fileManager.fileExists(atPath: repositoryRoot.appendingPathComponent("Makefile").path) else {
    fputs("Run this script from the Wrist Remote repository root.\n", stderr)
    exit(64)
}

do {
    for output in outputs {
        let destination = repositoryRoot.appendingPathComponent(output.path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try drawIcon(size: output.pixels).write(to: destination, options: .atomic)
    }
    print("Generated \(outputs.count) deterministic icon files.")
} catch {
    fputs("Icon generation failed: \(String(reflecting: error))\n", stderr)
    exit(1)
}
