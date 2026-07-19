import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: assert-selection-focus-screenshot.swift SCREENSHOT\n", stderr)
    exit(64)
}

let screenshotPath = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: screenshotPath),
      let source = image.cgImage(
          forProposedRect: nil,
          context: nil,
          hints: nil
      )
else {
    fputs("unable to load selection focus screenshot: \(screenshotPath)\n", stderr)
    exit(66)
}

let width = source.width
let height = source.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("unable to allocate selection focus pixel context\n", stderr)
    exit(70)
}

context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

let minimumFullWidthRun = max(1, Int(Double(width) * 0.35))
var qualifyingRows: [(row: Int, longestRun: Int)] = []
for y in 0 ..< height {
    var currentRun = 0
    var longestRun = 0
    for x in 0 ..< width {
        let offset = y * bytesPerRow + x * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let isSaturatedFocusBlue = blue >= 190
            && blue - red >= 65
            && blue - green >= 25
        if isSaturatedFocusBlue {
            currentRun += 1
            longestRun = max(longestRun, currentRun)
        } else {
            currentRun = 0
        }
    }
    if longestRun >= minimumFullWidthRun {
        qualifyingRows.append((row: y, longestRun: longestRun))
    }
}

var longestConsecutiveRows = 0
var currentConsecutiveRows = 0
var previousRow: Int?
for candidate in qualifyingRows {
    if let previousRow, candidate.row == previousRow + 1 {
        currentConsecutiveRows += 1
    } else {
        currentConsecutiveRows = 1
    }
    longestConsecutiveRows = max(
        longestConsecutiveRows,
        currentConsecutiveRows
    )
    previousRow = candidate.row
}

print("selection_focus_screenshot=\(screenshotPath)")
print("selection_focus_pixel_size=\(width)x\(height)")
print("selection_focus_minimum_full_width_run=\(minimumFullWidthRun)")
print(
    "selection_focus_qualifying_rows="
        + qualifyingRows.map { "\($0.row):\($0.longestRun)" }
        .joined(separator: ",")
)
print("selection_focus_max_consecutive_blue_rows=\(longestConsecutiveRows)")

guard longestConsecutiveRows <= 1 else {
    fputs(
        "selection focus visual is too heavy: found "
            + "\(longestConsecutiveRows) consecutive saturated-blue rows\n",
        stderr
    )
    exit(1)
}
