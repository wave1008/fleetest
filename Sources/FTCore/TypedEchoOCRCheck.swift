// TypedEchoOCRCheck.swift
// Flutter の数字系の欄が捨てた入力を、木の value が打った文字列のまま映す形(OI-40)を、OCR で確かめる対象の判定(純粋)

import Foundation

public enum TypedEchoOCRCheck {
    /// 欄の名前(id・ラベル・placeholder)が数字系を示す語。**木に入力の型(キーボードの種類)が載らない**ので名前でしか絞れない。
    /// 見逃しはあるが誤検知は増やさない側(警告だけ・OCR の費用を通常の入力に広げない)。
    /// 英語は**語の一致**(部分一致だと `age` が message・`pin` が shipping・`tel` が hotel に当たる)、日本語は部分一致
    static let numericWords: Set<String> = [
        "number", "numeric", "digit", "digits", "phone", "tel", "zip", "postal", "pin", "otp", "amount", "price",
        "qty", "quantity", "age",
    ]
    static let numericJapaneseHints: [String] = ["数", "電話", "郵便", "金額", "番号", "桁"]

    /// `field_number` / `phoneNumber` / `Zip code` を語に分ける(区切り記号と小文字→大文字の境目)
    static func words(_ name: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousIsLower = false
        for character in name {
            let boundary = !character.isLetter && !character.isNumber
            if boundary || (previousIsLower && character.isUppercase) {
                if !current.isEmpty { result.append(current.lowercased()) }
                current = ""
            }
            if !boundary { current.append(character) }
            previousIsLower = character.isLowercase
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }

    static func hasNumericName(_ name: String) -> Bool {
        words(name).contains(where: numericWords.contains) || numericJapaneseHints.contains(where: name.contains)
    }

    /// 打った後の木から、OCR で読む欄の枠を引く: 焦点のある(`focused == true`)入力欄で value が打った文字列のもの。
    /// 無ければ nil(確認をしない)
    public static func typedFieldFrame(in snapshot: SnapshotResponse, text: String) -> FTRect? {
        snapshot.elements.first {
            $0.focused == true && TypeReadback.isTextInput($0) && $0.value == text
        }?.frame
    }

    /// 読み返しの後に画面の欄を OCR で確かめるか。全部満たすときだけ:
    /// Flutter(他のフレームワークでは木が画面を映す)・OCR の段がオン(利用者が切った段は使わない)・置き換え入力・
    /// 入力欄・打った文字列に数字以外が含まれる(数字だけの文字列は数字の欄が受ける)・名前が数字系
    /// `locator` は書かれたセレクタ。Flutter の欄の id は外側の要素に付き、`#field_number >> .textField` の内側には無いので、スコープの id も名前に数える
    public static func shouldCheck(framework: AppUIFramework?, ocrMode: RegionTextGateMode, replace: Bool,
                                   text: String, element: ElementInfo, locator: FlowLocator?) -> Bool {
        guard framework == .flutter, ocrMode == .on, replace,
              TypeReadback.isTextInput(element), element.type != "secureTextField",
              !text.isEmpty, text.count <= 40,
              text.contains(where: { !$0.isNumber }) else { return false }
        let written = ([locator?.id] + (locator?.scope ?? []).map(\.id)).compactMap { $0 }
        let name = ([element.identifier, element.label, element.placeholder].compactMap { $0 } + written).joined(separator: " ")
        return hasNumericName(name)
    }
}
