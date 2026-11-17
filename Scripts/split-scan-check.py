#!/usr/bin/env python3
# ソースを分割した(塊を別ファイルへ移した)後に、元のファイルをファイル名で名指しして読む走査テストのうち、
# 移した中身を検査しているものを列挙する。名指しの走査は移した中身を黙って見なくなり、件数の下限や
# 「どこかに1つあれば緑」の形だと緑のまま検査の範囲だけが欠ける(AdbPolicyBuilderSyncTests・
# KeyboardOcclusionWiringTests で実際に起きた)。
#
# 使い方:
#   Scripts/split-scan-check.py <元のファイル> <移した先のファイル>...
#   例: Scripts/split-scan-check.py Sources/FTCore/StepExecutor+Actions.swift Sources/FTCore/StepExecutor+KeyboardCover.swift
#
# 判定は近似: テストの文字列リテラル(8文字以上)が移した先に現れるかだけを見る。挙がったテストは1本ずつ読み、
# 移した塊の中身を検査しているなら、移した先も読むように直す(本体だけを読むテストは extension を全部読む形へ)。
# 汎用の語(clearInput 等)の一致は誤検知なので読んで外す。挙がらなかったテストを「影響なし」と断じない
# (正規表現・組み立てた文字列での検査は拾えない)。
# 終了コード: 0 = 走査できた(候補の有無に関わらない)/ 2 = 引数・ファイルの誤り

import glob
import os
import re
import sys

MIN_LITERAL = 8
LITERAL = re.compile(r'#"(.*?)"#|"((?:[^"\\\n]|\\.){%d,})"' % MIN_LITERAL)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: split-scan-check.py <original file> <moved-to file>...", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    original, moved_paths = sys.argv[1], sys.argv[2:]
    for path in [original] + moved_paths:
        if not os.path.isfile(path):
            print(f"not a file: {path}", file=sys.stderr)
            return 2
    moved = {p: open(p, encoding="utf-8").read() for p in moved_paths}
    original_text = open(original, encoding="utf-8").read()
    name = os.path.basename(original)
    names_original = re.compile(r'["/]' + re.escape(name) + r'"')

    candidates = 0
    scanned = 0
    for test in sorted(glob.glob("Tests/**/*.swift", recursive=True)):
        source = open(test, encoding="utf-8").read()
        if not names_original.search(source):
            continue
        scanned += 1
        already = [os.path.basename(p) for p in moved_paths
                   if re.search(r'["/]' + re.escape(os.path.basename(p)) + r'"', source)]
        hits = set()
        for match in LITERAL.finditer(source):
            text = match.group(1) if match.group(1) is not None else match.group(2)
            if text is None or len(text) < MIN_LITERAL:
                continue
            text = text.replace('\\"', '"').replace("\\n", "\n")
            # 移した先のファイル名そのもの(見出しのコメントに書いてある)は中身の検査ではない
            if any(text.endswith(os.path.basename(p)) for p in moved_paths):
                continue
            for path, body in moved.items():
                if text in body:
                    where = "moved only" if text not in original_text else "moved and original"
                    hits.add((os.path.basename(path), where, text[:80].replace("\n", "⏎")))
        if not hits:
            continue
        candidates += 1
        note = f"  (already reads: {', '.join(already)})" if already else ""
        print(f"== {test}{note}")
        for moved_name, where, text in sorted(hits):
            print(f"    [{moved_name} / {where}] {text}")
    print(f"\n{scanned} test files name {name}; {candidates} check strings that now live in the moved-to files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
