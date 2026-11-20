// テストクラス/シナリオのメタデータと、objc ランタイムによるシナリオ自動発見。
// @TestClass マクロがこれらへの conformance・登録クラスを生成する(手書きも可能)。

import Foundation
import ObjectiveC

// FTDSL を import すれば FTCore の型(FTSwipeDirection 等)もそのまま使えるようにする
@_exported import FTCore

/// 1 シナリオ(@Test メソッド)のメタデータ
public struct FTScenarioDescriptor: Sendable {
    /// メソッド名(日本語可)
    public let name: String
    /// @Test の引数タイトル
    public let title: String
    /// @Deleted(クラスまたはメソッド)による論理削除。一括実行から除外される
    public let deleted: Bool
    /// @Draft(クラスまたはメソッド)による実装中マーク。一括実行から除外される
    /// (@Deleted との違いは意味だけ。両方付いているときは deleted を優先表示する)
    public let draft: Bool
    /// @Test(platform:)。"ios" / "android" / nil(クラスの platform: に従う)。
    /// **実効値はクラス側との合成**なので、読むときは effectivePlatform(classPlatform:) を通す
    public let platform: String?
    /// @Test(scenarioTimeout:) の秒。nil = 未指定(ScenarioHost.run が プロファイル → 既定の順に解く)
    public let scenarioTimeout: Int?
    /// @Order(n)(@RunInOrder のクラスのテストだけ。マクロ生成)
    public let order: Int?
    /// テストクラスの新規インスタンスを作ってメソッドを呼ぶクロージャ(マクロ生成)。
    /// @Sendable だが捕捉するのは常にクロージャ内で新規生成したインスタンスだけ
    /// (TestClassMacro.swift 参照)なので、テストクラス自体を Sendable にする必要は無い
    public let run: @Sendable () -> Void

    public init(name: String, title: String, deleted: Bool = false, draft: Bool = false,
                platform: String? = nil, scenarioTimeout: Int? = nil,
                order: Int? = nil,
                run: @escaping @Sendable () -> Void) {
        self.name = name
        self.title = title
        self.deleted = deleted
        self.draft = draft
        self.platform = platform
        self.scenarioTimeout = scenarioTimeout
        self.order = order
        self.run = run
    }

    /// メソッド側 ?? クラス側。どちらも無ければ nil(= 両OS対応 = run の既定 platform で走る)
    public func effectivePlatform(classPlatform: String?) -> String? {
        platform ?? classPlatform
    }
}

/// テストクラス(@TestClass)のメタデータ
public struct FTTestClassDescriptor {
    public let className: String
    /// "ios" / "android" / nil(両OS対応)
    public let platform: String?
    public let scenarios: [FTScenarioDescriptor]
    /// クラスの tearDownDevice()(マクロ生成。無ければ nil)。シナリオの子では走らせず、デバイスの仕事が
    /// 終わった後に親が `--device-teardown-only` の専用の子で呼ぶ(ScenarioHost.runDeviceTearDowns)。
    /// 非 nil の間、各シナリオの子は親へ deviceTearDown "declared" を申告する
    public let tearDownDevice: (@Sendable () -> Void)?
    /// クラスが beforeAll() を持つか(マクロ生成)。親が一覧(`ScenarioInfo.beforeAll`)で知り、その run で
    /// このクラスの beforeAll が終わるまで他のデバイスでこのクラスのシナリオを起動しない
    public let hasBeforeAll: Bool
    /// クラスの afterAll()(マクロ生成。無ければ nil)。シナリオの子では走らせず、run の全デバイスの仕事が終わった後に
    /// 親が `--after-all-only` の専用の子で run × クラスで1回呼ぶ(ScenarioHost.runAfterAlls)。
    /// 非 nil の間、各シナリオの子は親へ afterAll "declared" を申告する
    public let afterAll: (@Sendable () -> Void)?
    /// @RunOnSingleMachine / @RunOnSingleDevice / @RunInOrder(マクロ生成。無ければ nil)
    public let placement: ClassPlacement?

    public init(className: String, platform: String? = nil,
                scenarios: [FTScenarioDescriptor],
                tearDownDevice: (@Sendable () -> Void)? = nil,
                hasBeforeAll: Bool = false,
                afterAll: (@Sendable () -> Void)? = nil,
                placement: ClassPlacement? = nil) {
        self.className = className
        self.platform = platform
        self.scenarios = scenarios
        self.tearDownDevice = tearDownDevice
        self.hasBeforeAll = hasBeforeAll
        self.afterAll = afterAll
        self.placement = placement
    }

    /// 子の `list --json` が親へ渡す1クラス分の行(親は `ScenarioHost.list` でこれを decode する)
    public var scenarioInfos: [ScenarioInfo] {
        scenarios.map { scenario in
            ScenarioInfo(id: "\(className).\(scenario.name)", title: scenario.title,
                         platform: scenario.effectivePlatform(classPlatform: platform),
                         scenarioTimeout: scenario.scenarioTimeout,
                         deleted: scenario.deleted, draft: scenario.draft, beforeAll: hasBeforeAll,
                         placement: placement, order: scenario.order)
        }
    }
}

/// @TestClass が生成する conformance。手書きでの適合も可能(マクロはこの糖衣)
public protocol FTTestClassDefinition {
    static var ftDescriptor: FTTestClassDescriptor { get }
}

/// objc ランタイム発見用の基底クラス。@TestClass が __FTReg_<クラス名> サブクラスを生成する
open class FTScenarioRegistration: NSObject {
    open class var descriptor: FTTestClassDescriptor {
        fatalError("override FTScenarioRegistration.descriptor")
    }
}

/// `@RunHooks` のクラスのメタデータ(マクロ生成)。親は `--run-hook before|after` の専用の子でだけ呼ぶ
/// (シナリオの子・一覧の子では呼ばない)
public struct FTRunHooksDescriptor {
    public let className: String
    /// クラスの beforeRun()(無ければ nil)
    public let beforeRun: (@Sendable () -> Void)?
    /// クラスの afterRun()(無ければ nil)
    public let afterRun: (@Sendable () -> Void)?

    public init(className: String,
                beforeRun: (@Sendable () -> Void)? = nil,
                afterRun: (@Sendable () -> Void)? = nil) {
        self.className = className
        self.beforeRun = beforeRun
        self.afterRun = afterRun
    }
}

/// @RunHooks が生成する conformance。手書きでの適合も可能(マクロはこの糖衣)
public protocol FTRunHooksDefinition {
    static var ftRunHooksDescriptor: FTRunHooksDescriptor { get }
}

/// objc ランタイム発見用の基底クラス。@RunHooks が __FTRunHooksReg_<クラス名> サブクラスを生成する。
/// `FTScenarioRegistration` とは別の基底 = シナリオの一覧には載らない
open class FTRunHooksRegistration: NSObject {
    open class var descriptor: FTRunHooksDescriptor {
        fatalError("override FTRunHooksRegistration.descriptor")
    }
}

public enum ScenarioDiscovery {
    /// プロセスに読み込まれた全クラスのうち、`base` の派生クラスを返す。
    /// 重要: 未実現(unrealized)クラスへメッセージを送ると壊れるクラスがあるため、
    /// 判定は class_getSuperclass の C API 走査のみで行う(isSubclass(of:) 等は使わない)。
    private static func subclasses(of base: AnyClass) -> [AnyClass] {
        var count: UInt32 = 0
        guard let listPtr = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(listPtr)) }
        let buffer = UnsafeBufferPointer(start: listPtr, count: Int(count))

        var result: [AnyClass] = []
        for cls in buffer {
            var superclass: AnyClass? = class_getSuperclass(cls)
            while let s = superclass {
                if s == base {
                    result.append(cls)
                    break
                }
                superclass = class_getSuperclass(s)
            }
        }
        return result
    }

    public static func allTestClasses() -> [FTTestClassDescriptor] {
        subclasses(of: FTScenarioRegistration.self)
            .compactMap { ($0 as? FTScenarioRegistration.Type)?.descriptor }
            .sorted { $0.className < $1.className }
    }

    /// `@RunHooks` のクラス(クラス名の順)。**1つに絞る検査はここではしない**(一覧の段 = `list --json` の `runHooks` と
    /// `--run-hook` の入口が数える)
    public static func allRunHooks() -> [FTRunHooksDescriptor] {
        subclasses(of: FTRunHooksRegistration.self)
            .compactMap { ($0 as? FTRunHooksRegistration.Type)?.descriptor }
            .sorted { $0.className < $1.className }
    }

    /// ID(クラス名.メソッド名)でシナリオを探す。クラス名のみでシナリオが 1 つならそれを返す
    public static func find(id: String) -> (testClass: FTTestClassDescriptor, scenario: FTScenarioDescriptor)? {
        let classes = allTestClasses()
        for testClass in classes {
            for scenario in testClass.scenarios
            where "\(testClass.className).\(scenario.name)" == id {
                return (testClass, scenario)
            }
        }
        if let testClass = classes.first(where: { $0.className == id }),
           testClass.scenarios.count == 1 {
            return (testClass, testClass.scenarios[0])
        }
        return nil
    }
}
