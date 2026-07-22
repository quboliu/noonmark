import AppKit
import Foundation
import Vision

let screenshotPaths = Array(CommandLine.arguments.dropFirst())
guard screenshotPaths.isEmpty == false else {
    fputs("usage: assert-task-detail-density-screenshot.swift <screenshot>...\n", stderr)
    exit(64)
}

let forbiddenHeadings: Set<String> = [
    "完成进度",
    "分组与标签",
    "子任务",
    "附言",
    "Progress",
    "Group & Tags",
    "Subtasks",
    "Notes"
]

let requiredFragmentsByScreenshot: [String: [String]] = [
    "day-detail.png": ["30%", "分组", "标签", "添加子任务", "任务轨迹", "追加附言"],
    "pool-detail.png": ["分组", "标签", "添加子任务", "追加附言"],
    "future-detail.png": ["分组", "标签", "任务轨迹", "追加附言"],
    "unfinished-detail.png": ["0%", "历史事实", "任务轨迹"],
    "completed-detail.png": ["100%", "生活", "任务轨迹"]
]

private struct DetailTextAlignmentFixture {
    let titlePrefix: String
    let descriptionPrefix: String
    let axisPrefix: String
}

private let alignmentFixtures: [String: DetailTextAlignmentFixture] = [
    "day-detail.png": DetailTextAlignmentFixture(
        titlePrefix: "整理 Q3 OKR 草案",
        descriptionPrefix: "汇总三条产品线",
        axisPrefix: "分组"
    ),
    "pool-detail.png": DetailTextAlignmentFixture(
        titlePrefix: "读《卡片笔记写作法》第三章",
        descriptionPrefix: "任务池样例任务。",
        axisPrefix: "分组"
    )
]

// Vision must segment the detail rail itself. Segmenting the full 2400×1536
// window first and filtering observations afterwards can merge or truncate
// small Chinese labels before the rail filter ever sees them.
let rightRailRegion = CGRect(x: 0.75, y: 0, width: 0.25, height: 1)

for path in screenshotPaths {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        fputs("unable to load task-detail screenshot: \(path)\n", stderr)
        exit(1)
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    request.regionOfInterest = rightRailRegion
    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        fputs("task-detail OCR failed for \(path): \(error)\n", stderr)
        exit(2)
    }

    let rightRailObservations = request.results ?? []
    let rightRailLabels = rightRailObservations.compactMap { observation in
        observation.topCandidates(1).first?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard rightRailLabels.count >= 3 else {
        fputs("task detail OCR returned insufficient right-rail evidence for \(path)\n", stderr)
        exit(3)
    }
    let redundantHeadings = rightRailLabels.filter { label in
        forbiddenHeadings.contains { heading in
            label == heading || label.hasPrefix(heading)
        }
    }
    guard redundantHeadings.isEmpty else {
        fputs(
            "task detail still shows redundant headings in \(path): "
                + "\(redundantHeadings)\n",
            stderr
        )
        exit(4)
    }
    let screenshotName = URL(fileURLWithPath: path).lastPathComponent
    guard let requiredFragments = requiredFragmentsByScreenshot[screenshotName] else {
        fputs("task detail screenshot has no positive oracle: \(screenshotName)\n", stderr)
        exit(5)
    }
    let recognizedText = rightRailLabels.joined(separator: "\n")
    let missingFragments = requiredFragments.filter { recognizedText.contains($0) == false }
    guard missingFragments.isEmpty else {
        fputs(
            "task detail lost required controls or facts in \(path): "
                + "missing=\(missingFragments), labels=\(rightRailLabels)\n",
            stderr
        )
        exit(6)
    }
    if let fixture = alignmentFixtures[screenshotName] {
        func observation(withPrefix prefix: String) -> VNRecognizedTextObservation? {
            rightRailObservations.first { observation in
                observation.topCandidates(1).first?.string.hasPrefix(prefix) == true
            }
        }
        guard let title = observation(withPrefix: fixture.titlePrefix),
              let description = observation(withPrefix: fixture.descriptionPrefix),
              let axis = observation(withPrefix: fixture.axisPrefix)
        else {
            fputs("task detail alignment fixture was not recognized in \(path)\n", stderr)
            exit(7)
        }
        let railWidthInPoints = 1_200.0 * rightRailRegion.width
        let titleDelta = abs(title.boundingBox.minX - axis.boundingBox.minX)
            * railWidthInPoints
        let descriptionDelta = abs(description.boundingBox.minX - axis.boundingBox.minX)
            * railWidthInPoints
        let tolerance = 2.0
        guard max(titleDelta, descriptionDelta) <= tolerance else {
            fputs(
                String(
                    format: "task detail primary text is not left aligned in %@: "
                        + "title_delta=%.2fpt description_delta=%.2fpt tolerance=%.2fpt\n",
                    path,
                    titleDelta,
                    descriptionDelta,
                    tolerance
                ),
                stderr
            )
            exit(8)
        }
    }
    print("task_detail_density=ok path=\(path) right_rail_labels=\(rightRailLabels.count)")
}
