#!/usr/bin/swift

import AppKit
import Foundation
import Vision

enum ScreenshotVerificationError: Error, CustomStringConvertible {
    case invalidArguments
    case unknownScenario(String)
    case unreadableImage(String)
    case unexpectedDimensions(String, Int, Int, Int, Int)
    case missingMarker(String, String)
    case containsHan(String)
    case missingSettingsTitle(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "expected scenario/path pairs"
        case let .unknownScenario(scenario):
            return "unknown English screenshot scenario: \(scenario)"
        case let .unreadableImage(path):
            return "could not decode English screenshot: \(path)"
        case let .unexpectedDimensions(scenario, width, height, expectedWidth, expectedHeight):
            return "English screenshot \(scenario) has dimensions \(width)x\(height), expected \(expectedWidth)x\(expectedHeight)"
        case let .missingMarker(scenario, marker):
            return "English screenshot \(scenario) is missing marker: \(marker)"
        case let .containsHan(scenario):
            return "English screenshot \(scenario) contains recognized Han text"
        case let .missingSettingsTitle(title):
            return "English Settings screenshot is missing title: \(title)"
        }
    }
}

struct ScenarioContract {
    let marker: String
    let width: Int
    let height: Int
}

func expectedContract(for scenario: String) throws -> ScenarioContract {
    switch scenario {
    case "english-day":
        ScenarioContract(
            marker: "Coordinate the launch readiness",
            width: 1920,
            height: 1440
        )
    case "english-day-wide":
        ScenarioContract(
            marker: "Coordinate the launch readiness",
            width: 2880,
            height: 1800
        )
    case "english-day-history-header":
        ScenarioContract(marker: "History locked", width: 1920, height: 1440)
    case "english-pool":
        ScenarioContract(
            marker: "Draft the post-launch accessibility follow-up",
            width: 2400,
            height: 1536
        )
    case "english-future":
        ScenarioContract(
            marker: "Run the release candidate VoiceOver walkthrough",
            width: 2400,
            height: 1536
        )
    case "english-unfinished":
        ScenarioContract(
            marker: "Review the unresolved keyboard navigation findings",
            width: 2400,
            height: 1536
        )
    case "english-completed":
        ScenarioContract(
            marker: "Approve the final English navigation copy",
            width: 2400,
            height: 1536
        )
    case "english-calendar":
        ScenarioContract(
            marker: "A whole-month trace overview",
            width: 2400,
            height: 1536
        )
    case "english-settings":
        ScenarioContract(marker: "Zhulong Configuration", width: 1640, height: 1440)
    case "english-zhulong":
        ScenarioContract(
            marker: "Clarify what is vague and keep what is underway moving",
            width: 2400,
            height: 1536
        )
    default:
        throw ScreenshotVerificationError.unknownScenario(scenario)
    }
}

func normalized(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func recognize(path: String) throws -> (text: String, width: Int, height: Int) {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(
              forProposedRect: nil,
              context: nil,
              hints: nil
          )
    else {
        throw ScreenshotVerificationError.unreadableImage(path)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    return (text, cgImage.width, cgImage.height)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty, arguments.count.isMultiple(of: 2) else {
        throw ScreenshotVerificationError.invalidArguments
    }
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let scenario = arguments[index]
        let path = arguments[index + 1]
        let contract = try expectedContract(for: scenario)
        let observation = try recognize(path: path)
        guard observation.width == contract.width,
              observation.height == contract.height
        else {
            throw ScreenshotVerificationError.unexpectedDimensions(
                scenario,
                observation.width,
                observation.height,
                contract.width,
                contract.height
            )
        }
        let recognized = normalized(observation.text)
        guard recognized.localizedCaseInsensitiveContains(contract.marker) else {
            throw ScreenshotVerificationError.missingMarker(scenario, contract.marker)
        }
        guard recognized.range(of: "\\p{Han}", options: .regularExpression) == nil else {
            throw ScreenshotVerificationError.containsHan(scenario)
        }
        if scenario == "english-settings" {
            for title in [
                "Settings",
                "Zhulong Configuration",
                "Write & Privacy Boundaries",
            ] where !recognized.localizedCaseInsensitiveContains(title) {
                throw ScreenshotVerificationError.missingSettingsTitle(title)
            }
        }
        print("\(scenario)\tPASS\t\(contract.marker)")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
