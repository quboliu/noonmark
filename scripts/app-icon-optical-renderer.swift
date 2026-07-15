import AppKit
import CoreGraphics
import Foundation

private enum OpticalSize: Int {
    case compact = 16
    case regular = 32
}

private enum RenderError: Error, CustomStringConvertible {
    case invalidInteger(name: String, value: String)
    case invalidScale(opticalSize: Int, pixelSize: Int)
    case missingEnvironment(String)
    case missingContext
    case missingOutputImage
    case missingPNGData

    var description: String {
        switch self {
        case let .invalidInteger(name, value):
            "invalid \(name): \(value)"
        case let .invalidScale(opticalSize, pixelSize):
            "unsupported app icon optical scale: \(opticalSize)pt at \(pixelSize)px"
        case let .missingEnvironment(name):
            "missing environment variable: \(name)"
        case .missingContext:
            "failed to create optical app icon bitmap context"
        case .missingOutputImage:
            "failed to create optical app icon output image"
        case .missingPNGData:
            "failed to encode optical app icon PNG"
        }
    }
}

private struct OpticalIconRenderer {
    private let black = CGColor(
        red: 0.13,
        green: 0.13,
        blue: 0.12,
        alpha: 1
    )
    private let solarOrange = CGColor(
        red: 0.89,
        green: 0.31,
        blue: 0.13,
        alpha: 1
    )
    private let scaleOrange = CGColor(
        red: 0.76,
        green: 0.43,
        blue: 0.17,
        alpha: 1
    )
    private let tileBorder = CGColor(
        red: 0.88,
        green: 0.86,
        blue: 0.82,
        alpha: 1
    )

    let opticalSize: OpticalSize
    let pixelSize: Int

    func render() throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.missingContext
        }

        let logicalSize = CGFloat(opticalSize.rawValue)
        let outputScale = CGFloat(pixelSize) / logicalSize
        context.scaleBy(x: outputScale, y: outputScale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        drawTile(in: context, canvas: logicalSize)
        switch opticalSize {
        case .compact:
            drawCompactMark(in: context)
        case .regular:
            drawRegularMark(in: context)
        }

        guard let image = context.makeImage() else {
            throw RenderError.missingOutputImage
        }
        return image
    }

    private func drawTile(in context: CGContext, canvas: CGFloat) {
        let scale = canvas / 1024
        let tileRect = CGRect(
            x: 100 * scale,
            y: 100 * scale,
            width: 824 * scale,
            height: 824 * scale
        )
        let cornerRadius = 188 * scale
        let tilePath = CGPath(
            roundedRect: tileRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.addPath(tilePath)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.addPath(tilePath)
        context.setStrokeColor(tileBorder)
        context.setLineWidth(canvas == 16 ? 0.72 : 0.82)
        context.strokePath()
    }

    private func drawCompactMark(in context: CGContext) {
        let dial = CGMutablePath()
        dial.move(to: CGPoint(x: 9.2, y: 12.15))
        dial.addCurve(
            to: CGPoint(x: 3.55, y: 9.35),
            control1: CGPoint(x: 6.75, y: 13.05),
            control2: CGPoint(x: 4.2, y: 11.75)
        )
        dial.addCurve(
            to: CGPoint(x: 7.75, y: 3.45),
            control1: CGPoint(x: 2.85, y: 6.7),
            control2: CGPoint(x: 4.45, y: 4.05)
        )
        stroke(dial, color: black, width: 1.25, in: context)

        let scale = CGMutablePath()
        scale.move(to: CGPoint(x: 7.9, y: 3.45))
        scale.addCurve(
            to: CGPoint(x: 12.4, y: 7.1),
            control1: CGPoint(x: 10.65, y: 3.5),
            control2: CGPoint(x: 12.25, y: 4.85)
        )
        scale.addCurve(
            to: CGPoint(x: 12.0, y: 9.8),
            control1: CGPoint(x: 12.55, y: 8.1),
            control2: CGPoint(x: 12.35, y: 9.15)
        )
        stroke(scale, color: scaleOrange, width: 1.0, in: context)

        drawLine(from: CGPoint(x: 8.15, y: 3.5), to: CGPoint(x: 8.15, y: 4.65), width: 1.0, in: context)
        drawLine(from: CGPoint(x: 10.45, y: 4.05), to: CGPoint(x: 9.95, y: 5.1), width: 1.0, in: context)
        drawLine(from: CGPoint(x: 12.35, y: 7.0), to: CGPoint(x: 11.05, y: 7.0), width: 1.0, in: context)

        drawNeedle(
            baseLeft: CGPoint(x: 5.25, y: 5.0),
            baseRight: CGPoint(x: 7.15, y: 5.0),
            shoulder: CGPoint(x: 6.25, y: 5.35),
            tip: CGPoint(x: 10.15, y: 10.65),
            footWidth: 1.1,
            in: context
        )
        drawSun(center: CGPoint(x: 10.8, y: 11.55), radius: 1.2, in: context)
    }

    private func drawRegularMark(in context: CGContext) {
        let dial = CGMutablePath()
        dial.move(to: CGPoint(x: 18.45, y: 24.4))
        dial.addCurve(
            to: CGPoint(x: 7.15, y: 18.75),
            control1: CGPoint(x: 13.55, y: 26.15),
            control2: CGPoint(x: 8.35, y: 23.55)
        )
        dial.addCurve(
            to: CGPoint(x: 15.55, y: 6.85),
            control1: CGPoint(x: 5.75, y: 13.35),
            control2: CGPoint(x: 8.9, y: 8.05)
        )
        stroke(dial, color: black, width: 2.0, in: context)

        let scale = CGMutablePath()
        scale.move(to: CGPoint(x: 15.85, y: 6.85))
        scale.addCurve(
            to: CGPoint(x: 24.85, y: 14.25),
            control1: CGPoint(x: 21.35, y: 6.95),
            control2: CGPoint(x: 24.55, y: 9.75)
        )
        scale.addCurve(
            to: CGPoint(x: 24.0, y: 20.15),
            control1: CGPoint(x: 25.1, y: 16.4),
            control2: CGPoint(x: 24.75, y: 18.85)
        )
        stroke(scale, color: scaleOrange, width: 1.55, in: context)

        drawLine(from: CGPoint(x: 16.35, y: 6.95), to: CGPoint(x: 16.35, y: 9.1), width: 1.55, in: context)
        drawLine(from: CGPoint(x: 20.0, y: 7.85), to: CGPoint(x: 19.2, y: 9.9), width: 1.55, in: context)
        drawLine(from: CGPoint(x: 23.0, y: 10.35), to: CGPoint(x: 21.15, y: 11.6), width: 1.55, in: context)
        drawLine(from: CGPoint(x: 24.85, y: 14.25), to: CGPoint(x: 22.35, y: 14.25), width: 1.55, in: context)
        drawLine(from: CGPoint(x: 24.55, y: 18.0), to: CGPoint(x: 22.25, y: 17.2), width: 1.55, in: context)

        drawNeedle(
            baseLeft: CGPoint(x: 10.4, y: 9.9),
            baseRight: CGPoint(x: 14.35, y: 9.9),
            shoulder: CGPoint(x: 12.45, y: 10.55),
            tip: CGPoint(x: 20.4, y: 21.35),
            footWidth: 1.8,
            in: context
        )
        drawSun(center: CGPoint(x: 21.75, y: 23.2), radius: 2.15, in: context)
    }

    private func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat,
        in context: CGContext
    ) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        stroke(path, color: scaleOrange, width: width, in: context)
    }

    private func drawNeedle(
        baseLeft: CGPoint,
        baseRight: CGPoint,
        shoulder: CGPoint,
        tip: CGPoint,
        footWidth: CGFloat,
        in context: CGContext
    ) {
        let needle = CGMutablePath()
        needle.move(to: baseLeft)
        needle.addLine(to: shoulder)
        needle.addLine(to: tip)
        needle.addLine(to: baseRight)
        needle.closeSubpath()
        context.addPath(needle)
        context.setFillColor(black)
        context.fillPath()

        let foot = CGMutablePath()
        foot.move(to: baseLeft)
        foot.addLine(to: baseRight)
        stroke(foot, color: black, width: footWidth, in: context)
    }

    private func drawSun(
        center: CGPoint,
        radius: CGFloat,
        in context: CGContext
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.setFillColor(solarOrange)
        context.fillEllipse(in: rect)
    }

    private func stroke(
        _ path: CGPath,
        color: CGColor,
        width: CGFloat,
        in context: CGContext
    ) {
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokePath()
    }
}

private func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], value.isEmpty == false else {
        throw RenderError.missingEnvironment(name)
    }
    return value
}

private func integerEnvironment(_ name: String) throws -> Int {
    let value = try environment(name)
    guard let integer = Int(value) else {
        throw RenderError.invalidInteger(name: name, value: value)
    }
    return integer
}

do {
    let opticalValue = try integerEnvironment("NOONMARK_APP_ICON_OPTICAL_SIZE")
    let pixelSize = try integerEnvironment("NOONMARK_APP_ICON_SIZE")
    let outputPath = try environment("NOONMARK_APP_ICON_OUTPUT")
    guard let opticalSize = OpticalSize(rawValue: opticalValue) else {
        throw RenderError.invalidInteger(
            name: "NOONMARK_APP_ICON_OPTICAL_SIZE",
            value: String(opticalValue)
        )
    }
    guard pixelSize == opticalValue || pixelSize == opticalValue * 2 else {
        throw RenderError.invalidScale(
            opticalSize: opticalValue,
            pixelSize: pixelSize
        )
    }

    let image = try OpticalIconRenderer(
        opticalSize: opticalSize,
        pixelSize: pixelSize
    ).render()
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw RenderError.missingPNGData
    }
    try data.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
