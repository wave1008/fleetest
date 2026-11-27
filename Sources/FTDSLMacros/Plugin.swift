import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct FTDSLPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TestClassMacro.self,
        TestMacro.self,
        DeletedMacro.self,
        DraftMacro.self,
        FTCommandMacro.self,
        RunOnSingleMachineMacro.self,
        RunOnSingleDeviceMacro.self,
        RunInOrderMacro.self,
        OrderMacro.self,
        RequiresDeviceMacro.self,
        ExcludesDeviceMacro.self,
        RunHooksMacro.self,
    ]
}
