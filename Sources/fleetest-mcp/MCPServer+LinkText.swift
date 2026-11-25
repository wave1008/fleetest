// ft_tap の linkText:(段落の中のリンクの語を押す)。位置の決め方は DSL の tap(sel, linkText:) と同じ `LinkTextLocator`
// (木の子孫 → OCR)。**OCR は fmAndVision: true のときだけ**(MCP の既定 = DR-61)。DSL の読み手の回復待ちは持たない
// (外枠の無い呼び手は待たない = StepExecutor+LinkText と同じ)

import FTAndroid
import FTCore
import Foundation

extension MCPServer {

    func ftTapLinkText(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let linkText = try Self.stringArgument(args, "linkText") else {
            throw MCPError("linkText must be a string")
        }
        guard args["x"] == nil, args["y"] == nil else {
            throw MCPError("linkText names text inside an element — pass selector (or ref) with it, not x/y")
        }
        guard let ref = try Self.intArgument(args, "ref") else {
            throw MCPError("linkText needs the element that draws the text: pass selector (preferred) or ref")
        }
        let d = try await driver(args)
        let target = try await verifiedRef(ref, driver: d, args: args, operation: "tap")
        guard let tree = lastSnapshots[Self.sessionKey(args)],
              let element = tree.elements.first(where: { $0.ref == target.ref }) else {
            throw MCPError("ref \(ref) is not in the latest tree — take ft_snapshot and retry")
        }
        let head = "cannot find the link text \"\(linkText)\" inside \(TapTargetGeometry.describe(element)):"
            + " no descendant in the tree has that label, and "
        var point = LinkTextLocator.treePoint(linkText: linkText, element: element, in: tree.elements)
            .map { (x: $0.x, y: $0.y, source: $0.source) }
        if point == nil {
            guard args["fmAndVision"] as? Bool == true else {
                throw MCPError(head + "reading the element's pixels (OCR) is off in MCP unless fmAndVision is true —"
                    + " pass fmAndVision: true to find it here. The scenario line tap(selector, linkText: \"\(linkText)\")"
                    + " reads the pixels in a run either way")
            }
            guard OCRSupport.isSupported else {
                throw MCPError(head + "reading the element's pixels is unavailable (\(OCRSupport.requirement))")
            }
            _ = await RegionText.awaitModelCompile(mode: .on)
            let isAndroid = bridges[Self.sessionKey(args)] == "android" || d is AndroidDriver
            let elementTexts = [element.label, element.value].compactMap { $0 }
            var lines: [String] = []
            for attempt in 1...LinkTextLocator.ocrShotAttempts {
                if attempt > 1 { try? await Task.sleep(for: LinkTextLocator.ocrReshotInterval) }
                let png = try await d.screenshot()
                let frame = element.frame, screen = tree.screen
                let outcome = await TaskBudget.run(LinkTextLocator.ocrBudget) {
                    await RegionText.locateLink(linkText: linkText, pngData: png, frame: frame, screen: screen,
                                                  elementTexts: elementTexts)
                }
                guard case .value(let located) = outcome else {
                    throw MCPError(head + "OCR did not finish within \(LinkTextLocator.ocrBudget) (the text recognizer is stuck)")
                }
                // iOS は読みが要素のテキストと食い違う絵(遷移の途中)を撮り直す(DSL の ocrRound と同じ)
                if !isAndroid, attempt < LinkTextLocator.ocrShotAttempts, let located, !located.lines.isEmpty,
                   !LinkTextLocator.readMatchesElement(lines: located.lines, elementTexts: elementTexts) {
                    lines = located.lines
                    continue
                }
                if let located {
                    lines = located.lines
                    if let p = located.point { point = (x: p.x, y: p.y, source: .ocr); break }
                }
                if !lines.isEmpty { break }
            }
            guard point != nil else {
                throw MCPError(head + "the text was not found in the element's pixels ("
                    + (lines.isEmpty ? "OCR read no text in the element"
                        : "OCR read: " + lines.map { "\"\($0)\"" }.joined(separator: ", ")) + ")")
            }
        }
        guard let point else { throw MCPError(head + "it could not be located") }
        if let offscreen = Self.offscreenCoordinateError(
            x: point.x, y: point.y, screen: await coordinateScreen(d, args: args),
            bridge: bridges[Self.sessionKey(args)]) { throw offscreen }
        let keyboardWarning = await keyboardCoordinateWarning(d, x: point.x, y: point.y, args: args)
        let linkFrontWarning = await coordinateFrontAppWarning(d, args: args)
        try await d.tap(x: point.x, y: point.y)
        recordInteraction(action: "tap", resolvedRef: target.ref, args: args, linkText: linkText)
        lastTapTargets[Self.sessionKey(args)] = nil
        return text("tap link text \"\(linkText)\" at (\(Int(saturating: point.x.rounded())), \(Int(saturating: point.y.rounded())))"
            + " — located by \(point.source.rawValue) inside \(RefGuard.describe(element)); done"
            + target.note + suppressedTopBandWarning(ref: target.ref, args: args)
            + keyboardWarning + linkFrontWarning
            + waitForWithoutSnapshotAfterNote(args)
            + (await snapshotAfterBody(args, outsideTheAppTree: false)))
    }
}
