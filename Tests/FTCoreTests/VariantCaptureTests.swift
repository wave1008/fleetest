// ft_capture_element の variant: 入口の検査・保存名・表示条件の出し入れ(開始時の値へ戻す)と、画像の失敗文の言い分け
import XCTest
@testable import FTCore

final class VariantCaptureTests: XCTestCase {
    private func variant(_ name: String, appearance: FTAppearance? = nil, textSize: FTTextSize? = nil,
                         orientation: String? = nil) -> ResolvedVariant {
        ResolvedVariant(name: name, appearance: appearance, textSize: textSize, orientation: orientation)
    }

    func testRefusalsAreAllAtTheEntrance() {
        XCTAssertNil(VariantCapture.refusal(variant: nil, selector: nil, ref: 1, name: "x", profile: nil))
        XCTAssertNil(VariantCapture.refusal(variant: "dark", selector: "#a", ref: nil, name: nil, profile: "p"))
        XCTAssertTrue(VariantCapture.refusal(variant: "dark", selector: nil, ref: 1, name: nil, profile: "p")!.contains("ref"))
        XCTAssertTrue(VariantCapture.refusal(variant: "dark", selector: nil, ref: nil, name: nil, profile: "p")!.contains("requires selector"))
        XCTAssertTrue(VariantCapture.refusal(variant: "dark", selector: "#a", ref: nil, name: "n.png", profile: "p")!.contains("name"))
        XCTAssertTrue(VariantCapture.refusal(variant: "dark", selector: "#a", ref: nil, name: nil, profile: nil)!.contains("profile"))
    }

    func testResolveRefusesUnknownOrientationAndUnsafeNames() throws {
        let declared = [variant("default"), variant("dark", appearance: .dark), variant("land", orientation: "landscape"),
                        variant("a@i")]
        XCTAssertEqual(try VariantCapture.resolve(name: "dark", profile: "p", declared: declared).appearance, .dark)
        for bad in ["nope", "land", "a@i"] {
            XCTAssertThrowsError(try VariantCapture.resolve(name: bad, profile: "p", declared: declared), bad)
        }
        XCTAssertThrowsError(try VariantCapture.resolve(name: "dark", profile: "p", declared: []))
    }

    func testFileNameCarriesTheVariantAndNoOSMark() {
        let name = VariantCapture.fileName(variant: "dark", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasSuffix("-variant-dark.png"))
        XCTAssertFalse(name.contains("@"))
        XCTAssertFalse(name.hasPrefix("capture-"))
    }

    /// 値を保持するだけの端末
    private final class FakeTransport: DisplaySettingsTransport, @unchecked Sendable {
        var state: DisplayObservation
        var applied: [DisplayChange] = []
        var failApply = false
        init(_ state: DisplayObservation) { self.state = state }
        func read(budget: DisplayCommandBudget) -> DisplayReadResult { DisplayReadResult(observation: state, failure: nil) }
        func apply(_ change: DisplayChange, budget: DisplayCommandBudget) -> DisplayApplyResult {
            applied.append(change)
            if failApply { return DisplayApplyResult(failedKeys: change.keys, failure: "boom") }
            if let a = change.appearance { state.appearance = a.rawValue }
            if let t = change.textSize { state.textSize = t.rawValue }
            if let l = change.largerAccessibilitySizes { state.largerAccessibilitySizes = l }
            return .ok
        }
    }

    func testSessionSetsTheVariantAndRestoresTheStartingValues() {
        // 開始時が基準でない(dark・large)ことが「基準へ戻す」と「開始時へ戻す」の違いを出す
        let device = FakeTransport(DisplayObservation(appearance: "dark", textSize: "large", largerAccessibilitySizes: false))
        var session = VariantDisplaySession(transport: device, variant: variant("big", appearance: .light, textSize: .accessibility))
        XCTAssertNil(session.begin())
        XCTAssertEqual(device.state.appearance, "light")
        XCTAssertEqual(device.state.textSize, "accessibility")
        XCTAssertEqual(device.state.largerAccessibilitySizes, true)
        let line = session.restore()
        XCTAssertEqual(device.state.appearance, "dark")
        XCTAssertEqual(device.state.textSize, "large")
        XCTAssertEqual(device.state.largerAccessibilitySizes, false)
        XCTAssertTrue(line.contains("returned"), line)
    }

    func testSessionRestoreReportsWhenItCannot() {
        let device = FakeTransport(DisplayObservation(appearance: "dark", textSize: "default"))
        var session = VariantDisplaySession(transport: device, variant: variant("light", appearance: .light))
        XCTAssertNil(session.begin())
        device.failApply = true
        XCTAssertTrue(session.restore().hasPrefix("⚠️"))
    }

    func testSessionBeginFailureStillLetsRestoreRun() {
        let device = FakeTransport(DisplayObservation(appearance: "light", textSize: "default"))
        device.failApply = true
        var session = VariantDisplaySession(transport: device, variant: variant("dark", appearance: .dark))
        XCTAssertNotNil(session.begin())
        XCTAssertFalse(session.restore().hasPrefix("⚠️"))
    }

    // MARK: 画像の言い分け

    func testVariantHintSaysWhetherTheVariantHasItsOwnImage() {
        XCTAssertNil(FindImage.variantTemplateHint(variant: nil, label: "[Logo]", hasVariantTemplate: false))
        let none = FindImage.variantTemplateHint(variant: "dark", label: "[Logo]", hasVariantTemplate: false)!
        XCTAssertTrue(none.contains("ft_capture_element") && none.contains("-variant-dark"), none)
        let some = FindImage.variantTemplateHint(variant: "dark", label: "[Logo]", hasVariantTemplate: true)!
        XCTAssertFalse(some.contains("ft_capture_element"), some)
        XCTAssertTrue(some.contains("did not match"), some)
    }

    func testHasVariantTemplateReadsTheLabelFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("@i/[Logo]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: folder.appendingPathComponent("20260101-000000-000-variant-dark.png"))
        try Data([0]).write(to: folder.appendingPathComponent("base.png"))
        XCTAssertTrue(FindImage.hasVariantTemplate(variant: "dark", label: "[Logo]", classifierDirectory: root))
        XCTAssertFalse(FindImage.hasVariantTemplate(variant: "light", label: "[Logo]", classifierDirectory: root))
        XCTAssertFalse(FindImage.hasVariantTemplate(variant: "dark", label: "[Other]", classifierDirectory: root))
    }

    func testTemplateNoteNamesTheTemplateFile() {
        let element = ElementInfo(ref: 1, type: "image", identifier: nil, label: nil, value: nil, placeholder: nil,
                                  enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let match = FindImage.Match(element: element, visibleFrame: element.frame, distance: 0.2,
                                    template: URL(fileURLWithPath: "/p/[Logo]/a-variant-dark.png"))
        let miss = StepExecutor.ImageScan(found: [], nearest: match, classified: false)
        XCTAssertEqual(StepExecutor.templateNote(miss, single: true), "nearest template a-variant-dark.png")
        let hit = StepExecutor.ImageScan(found: [match], nearest: match, classified: false)
        XCTAssertEqual(StepExecutor.templateNote(hit, single: true), "template a-variant-dark.png")
        XCTAssertEqual(StepExecutor.templateNote(hit, single: false), "templates a-variant-dark.png")
        let failure = StepExecutor.existImageFailure(label: "[Logo]", scan: miss, threshold: 0.15, attached: false,
                                                     variantHint: "HINT")
        XCTAssertTrue(failure.contains("nearest template a-variant-dark.png") && failure.contains("; HINT"), failure)
    }
}
