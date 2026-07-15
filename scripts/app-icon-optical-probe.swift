import AppKit
import CoreGraphics
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case unreadableImage(String)
    case missingCGImage(String)
    case missingContext(String)
    case failedCheck(String)

    var description: String {
        switch self {
        case let .invalidArguments(message),
             let .failedCheck(message):
            message
        case let .unreadableImage(path):
            "unreadable app icon probe image: \(path)"
        case let .missingCGImage(path):
            "app icon probe image has no CGImage: \(path)"
        case let .missingContext(path):
            "failed to create app icon probe context: \(path)"
        }
    }
}

private struct PixelBounds: CustomStringConvertible {
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min

    var isEmpty: Bool { maxX < minX || maxY < minY }
    var width: Int { isEmpty ? 0 : maxX - minX + 1 }
    var height: Int { isEmpty ? 0 : maxY - minY + 1 }

    var description: String {
        isEmpty ? "empty" : "\(minX),\(minY)-\(maxX),\(maxY)"
    }

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

private struct PixelImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(path: String) throws {
        guard let image = NSImage(contentsOfFile: path) else {
            throw ProbeError.unreadableImage(path)
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw ProbeError.missingCGImage(path)
        }

        width = cgImage.width
        height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProbeError.missingContext(path)
        }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        bytes = pixels
    }

    func channels(x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let index = (y * width + x) * 4
        return (
            Int(bytes[index]),
            Int(bytes[index + 1]),
            Int(bytes[index + 2]),
            Int(bytes[index + 3])
        )
    }
}

private struct SmallIconMetrics {
    let alphaBounds: PixelBounds
    let motifBounds: PixelBounds
    let visibleCount: Int
    let opaqueCount: Int
    let edgeAlphaCount: Int
    let darkCount: Int
    let orangeCount: Int
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ProbeError.failedCheck(message)
    }
}

private func unpremultiplied(_ channel: Int, alpha: Int) -> Int {
    guard alpha > 0 else { return 0 }
    return min(255, channel * 255 / alpha)
}

private func metrics(for image: PixelImage) -> SmallIconMetrics {
    var alphaBounds = PixelBounds()
    var motifBounds = PixelBounds()
    var visibleCount = 0
    var opaqueCount = 0
    var edgeAlphaCount = 0
    var darkCount = 0
    var orangeCount = 0

    for y in 0..<image.height {
        for x in 0..<image.width {
            let channels = image.channels(x: x, y: y)
            if channels.alpha > 8 {
                visibleCount += 1
                alphaBounds.include(x: x, y: y)
                if x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                    edgeAlphaCount += 1
                }
            }
            if channels.alpha > 247 {
                opaqueCount += 1
            }
            guard channels.alpha > 127 else { continue }

            let red = unpremultiplied(channels.red, alpha: channels.alpha)
            let green = unpremultiplied(channels.green, alpha: channels.alpha)
            let blue = unpremultiplied(channels.blue, alpha: channels.alpha)
            if max(red, green, blue) < 150 {
                darkCount += 1
                motifBounds.include(x: x, y: y)
            } else if red - green > 24, green - blue > 8 {
                orangeCount += 1
                motifBounds.include(x: x, y: y)
            }
        }
    }

    return SmallIconMetrics(
        alphaBounds: alphaBounds,
        motifBounds: motifBounds,
        visibleCount: visibleCount,
        opaqueCount: opaqueCount,
        edgeAlphaCount: edgeAlphaCount,
        darkCount: darkCount,
        orangeCount: orangeCount
    )
}

private func validateSmall(path: String, expectedSize: Int) throws {
    let image = try PixelImage(path: path)
    try require(
        image.width == expectedSize && image.height == expectedSize,
        "optical app icon has invalid dimensions: \(path)"
    )

    let result = metrics(for: image)
    let canvasArea = Double(expectedSize * expectedSize)
    let alphaWidthRatio = Double(result.alphaBounds.width) / Double(expectedSize)
    let alphaHeightRatio = Double(result.alphaBounds.height) / Double(expectedSize)
    let opaqueRatio = Double(result.opaqueCount) / canvasArea
    let darkRatio = Double(result.darkCount) / canvasArea
    let orangeRatio = Double(result.orangeCount) / canvasArea
    let motifWidthRatio = Double(result.motifBounds.width) / Double(expectedSize)
    let motifHeightRatio = Double(result.motifBounds.height) / Double(expectedSize)
    let minimumMotifGap = max(1, Int((Double(expectedSize) * 0.09).rounded(.down)))

    try require(result.alphaBounds.isEmpty == false, "optical app icon has no alpha body: \(path)")
    try require(result.motifBounds.isEmpty == false, "optical app icon has no mark: \(path)")
    try require(result.edgeAlphaCount == 0, "optical app icon touches the canvas edge: \(path)")
    try require(
        (0.82...0.90).contains(alphaWidthRatio)
            && (0.82...0.90).contains(alphaHeightRatio),
        "optical app icon tile occupancy is out of bounds: \(path)"
    )
    try require(
        (0.50...0.68).contains(opaqueRatio),
        "optical app icon opaque occupancy is out of bounds: \(path)"
    )
    try require(
        (0.06...0.12).contains(darkRatio),
        "optical app icon dark mark is not legible: \(path)"
    )
    try require(
        (0.05...0.12).contains(orangeRatio),
        "optical app icon orange mark is not legible: \(path)"
    )
    try require(
        (0.58...0.68).contains(motifWidthRatio)
            && (0.58...0.68).contains(motifHeightRatio),
        "optical app icon mark occupancy is out of bounds: \(path)"
    )
    try require(
        result.motifBounds.minX - result.alphaBounds.minX >= minimumMotifGap
            && result.motifBounds.minY - result.alphaBounds.minY >= minimumMotifGap
            && result.alphaBounds.maxX - result.motifBounds.maxX >= minimumMotifGap
            && result.alphaBounds.maxY - result.motifBounds.maxY >= minimumMotifGap,
        "optical app icon mark crowds the tile edge: \(path)"
    )

    let name = URL(fileURLWithPath: path).lastPathComponent
    print(
        "Optical probe \(name): alpha=\(result.alphaBounds) "
            + "visible=\(result.visibleCount) opaque=\(result.opaqueCount) "
            + "edge=\(result.edgeAlphaCount) dark=\(result.darkCount) "
            + "orange=\(result.orangeCount) motif=\(result.motifBounds)"
    )
}

private func validateDistinct(leftPath: String, rightPath: String) throws {
    let left = try PixelImage(path: leftPath)
    let right = try PixelImage(path: rightPath)
    try require(
        left.width == right.width && left.height == right.height,
        "cannot compare differently sized app icon variants"
    )

    var differentPixels = 0
    for y in 0..<left.height {
        for x in 0..<left.width {
            let lhs = left.channels(x: x, y: y)
            let rhs = right.channels(x: x, y: y)
            if abs(lhs.red - rhs.red) > 3
                || abs(lhs.green - rhs.green) > 3
                || abs(lhs.blue - rhs.blue) > 3
                || abs(lhs.alpha - rhs.alpha) > 3
            {
                differentPixels += 1
            }
        }
    }
    let requiredDifference = max(1, Int(Double(left.width * left.height) * 0.10))
    try require(
        differentPixels >= requiredDifference,
        "app icon optical variant is only a trivial resample: \(leftPath)"
    )
    print(
        "Optical distinction \(URL(fileURLWithPath: leftPath).lastPathComponent): "
            + "\(differentPixels)/\(left.width * left.height) pixels differ"
    )
}

private func validateRoundTrip(sourcePath: String, extractedPath: String) throws {
    let source = try PixelImage(path: sourcePath)
    let extracted = try PixelImage(path: extractedPath)
    try require(
        source.width == extracted.width && source.height == extracted.height,
        "icns round-trip changed app icon dimensions: \(sourcePath)"
    )

    var opaqueColorDifferences = 0
    for y in 0..<source.height {
        for x in 0..<source.width {
            let lhs = source.channels(x: x, y: y)
            let rhs = extracted.channels(x: x, y: y)
            try require(
                lhs.alpha == rhs.alpha,
                "icns round-trip changed app icon alpha at \(x),\(y): \(sourcePath)"
            )
            if lhs.alpha == 255,
               lhs.red != rhs.red || lhs.green != rhs.green || lhs.blue != rhs.blue
            {
                opaqueColorDifferences += 1
            }
        }
    }
    try require(
        opaqueColorDifferences == 0,
        "icns round-trip changed opaque app icon colors: \(sourcePath)"
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--small":
            guard index + 2 < arguments.count,
                  let size = Int(arguments[index + 2])
            else {
                throw ProbeError.invalidArguments("--small requires PATH SIZE")
            }
            try validateSmall(path: arguments[index + 1], expectedSize: size)
            index += 3
        case "--distinct":
            guard index + 2 < arguments.count else {
                throw ProbeError.invalidArguments("--distinct requires LEFT RIGHT")
            }
            try validateDistinct(
                leftPath: arguments[index + 1],
                rightPath: arguments[index + 2]
            )
            index += 3
        case "--round-trip":
            guard index + 2 < arguments.count else {
                throw ProbeError.invalidArguments("--round-trip requires SOURCE EXTRACTED")
            }
            try validateRoundTrip(
                sourcePath: arguments[index + 1],
                extractedPath: arguments[index + 2]
            )
            index += 3
        default:
            throw ProbeError.invalidArguments("unknown app icon probe argument: \(flag)")
        }
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
