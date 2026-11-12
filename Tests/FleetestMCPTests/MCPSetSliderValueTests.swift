// ft_set_slider_value: selector(または ref)でスライダーを指し、DSL と同じ `SliderTarget` とドライバ経路(`setSliderValue`)で合わせる。
// id が外側の入れ物に付いていれば中のスライダーへ寄せ、中に2つ以上なら撃たずに断る。下書きは `setSliderValue("<selector>", <数>)` の行。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPSetSliderValueTests: XCTestCase {

    private func make(_ elements: [ElementInfo]) -> (MCPServer, FakeDriver) {
        let fake = FakeDriver()
        fake.foregroundBundleID = "com.example.app"
        fake.snapshotResponse.elements = elements
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return (server, fake)
    }

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil, value: String? = nil,
                    x: Double, width: Double, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: 100, width: width, height: 48), depth: depth)
    }

    private func texts(_ result: [[String: Any]]) -> String {
        result.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testSliderIsSetWithTheTreesCurrentValue() async throws {
        let (server, fake) = make([el(1, "slider", id: "volume", value: "50", x: 16, width: 370)])
        let text = texts(try await server.call(tool: "ft_set_slider_value", args: ["selector": "#volume", "value": 75.0]))
        XCTAssertTrue(fake.calls.contains("setSliderValue(ref:1,id:volume,current:50,value:75)"), "\(fake.calls)")
        XCTAssertTrue(text.contains("now reads \"75\""), text)
    }

    /// Flutter の Android の形: id は外側の入れ物・スライダーは子で値はラベル。子へ寄せ、ラベルを今の値として渡す
    func testContainerMovesTheInnerSliderAndPassesItsLabelAsTheValue() async throws {
        let (server, fake) = make([el(1, "other", id: "slider_volume", x: 16, width: 370),
                                   el(2, "slider", label: "50%", x: 180, width: 48, depth: 2)])
        _ = try await server.call(tool: "ft_set_slider_value", args: ["selector": "#slider_volume", "value": 75.0])
        XCTAssertTrue(fake.calls.contains("setSliderValue(ref:2,id:nil,current:50%,value:75)"), "\(fake.calls)")
    }

    /// 範囲スライダー(つまみ2つ)は撃たずに断る
    func testContainerWithTwoSlidersIsRefusedWithoutSending() async throws {
        let (server, fake) = make([el(1, "other", id: "range", x: 16, width: 370),
                                   el(2, "slider", value: "20", x: 30, width: 48, depth: 2),
                                   el(3, "slider", value: "80", x: 300, width: 48, depth: 2)])
        do {
            _ = try await server.call(tool: "ft_set_slider_value", args: ["selector": "#range", "value": 50.0])
            XCTFail("2つのスライダーを持つ入れ物を通した")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("holds 2 sliders"), error.localizedDescription)
        }
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("setSliderValue(") }, "\(fake.calls)")
    }

    /// 止まった値の文言を運ぶ(ドライバの 422)
    func testFailureCarriesTheStoppedValue() async throws {
        let (server, fake) = make([el(1, "slider", id: "volume", value: "50", x: 16, width: 370)])
        fake.scriptedSliderFailure = "the slider stopped at '80%', not 75: one step moves it past the value"
        do {
            _ = try await server.call(tool: "ft_set_slider_value", args: ["selector": "#volume", "value": 75.0])
            XCTFail("失敗を通した")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped at '80%'"), error.localizedDescription)
        }
    }

    /// どのブリッジも動かせなければ(501)DSL と同じく帯の上のタップで合わせる(撃った座標はスライダーの帯の上)
    func testIncapableBridgeFallsToTappingAlongTheTrack() async throws {
        let (server, fake) = make([el(1, "slider", id: "volume", value: "50", x: 16, width: 370)])
        fake.scriptedSliderFailure = "no slider-type element"
        fake.scriptedSliderFailureStatus = 501
        do {
            _ = try await server.call(tool: "ft_set_slider_value", args: ["selector": "#volume", "value": 75.0])
            XCTFail("偽の木は値が動かないので、範囲の外で止まるはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tapping along its track was tried"), error.localizedDescription)
        }
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("tap(x:") }, "\(fake.calls)")
    }
}
