// remoteCompatGate.test.mjs
// remoteCompatGate.ts(decideRemoteCompat)のユニットテスト。node:test で実行する。
// esbuild が "../src/remoteCompatGate"(拡張子なし)を remoteCompatGate.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { decideRemoteCompat, hasXcodeSelectionError } from "../src/remoteCompatGate";

const okMachine = (machine) => ({
  machine,
  reachable: true,
  revision: "abc1234",
  revisionCompatible: true,
  toolchain: "swift-6.0",
  toolchainCompatible: true,
  error: null,
});

test("machines が空: proceed(プロファイルにリモート機なし)", () => {
  const decision = decideRemoteCompat({ machines: [] });
  assert.deepEqual(decision, { kind: "proceed", advisoryMachines: [] });
});

test("全マシン compatible: proceed", () => {
  const decision = decideRemoteCompat({
    machines: [okMachine("M1Max"), okMachine("M1Ultra")],
    localRevision: "abc1234",
  });
  assert.deepEqual(decision, { kind: "proceed", advisoryMachines: [] });
});

test("advisory のみ(ベータ seed 違い): proceed かつ advisoryMachines に載る・incompatible には入らない", () => {
  const machine = {
    ...okMachine("M1Max"),
    toolchain: "Xcode 16.0 beta 3",
    toolchainCompatible: true,
    toolchainAdvisory: "Xcode 16.0 beta 3 vs beta 2 on M1Ultra",
  };
  const decision = decideRemoteCompat({ machines: [machine, okMachine("M1Ultra")] });
  assert.deepEqual(decision, {
    kind: "proceed",
    advisoryMachines: [{ machine: "M1Max", advisory: "Xcode 16.0 beta 3 vs beta 2 on M1Ultra" }],
  });
});

test("blocking な不一致と advisory が混在: ask かつ advisoryMachines も載る", () => {
  const staleRev = { ...okMachine("M1Max"), revisionCompatible: false };
  const advisory = {
    ...okMachine("M1Ultra"),
    toolchainCompatible: true,
    toolchainAdvisory: "Xcode 16.0 beta 3 vs beta 2 on M1Max",
  };
  const decision = decideRemoteCompat({ machines: [staleRev, advisory] });
  assert.equal(decision.kind, "ask");
  assert.deepEqual(decision.incompatible.map((m) => m.machine), ["M1Max"]);
  assert.deepEqual(decision.advisoryMachines, [
    { machine: "M1Ultra", advisory: "Xcode 16.0 beta 3 vs beta 2 on M1Max" },
  ]);
});

test("rev ズレのみ: ask かつ canUpdate=true・updatableMachines に名前が入る", () => {
  const machine = { ...okMachine("M1Max"), revision: "deadbee", revisionCompatible: false };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableMachines, ["M1Max"]);
  assert.deepEqual(decision.incompatible, [machine]);
  assert.deepEqual(decision.snapshotMachines, []);
});

test("unreachable が混在: ask かつ canUpdate=false(align では直らない)", () => {
  const reachableButStale = { ...okMachine("M1Max"), revisionCompatible: false };
  const unreachable = {
    machine: "M1Ultra",
    reachable: false,
    revision: null,
    revisionCompatible: null,
    toolchain: null,
    toolchainCompatible: null,
    error: "connection timed out",
  };
  const decision = decideRemoteCompat({
    machines: [reachableButStale, unreachable, okMachine("M2Studio")],
  });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
  assert.deepEqual(
    decision.incompatible.map((m) => m.machine),
    ["M1Max", "M1Ultra"],
  );
});

test("toolchain ズレ: ask かつ canUpdate=false(align は rev しか直せない)", () => {
  const machine = { ...okMachine("M1Max"), toolchain: "swift-5.9", toolchainCompatible: false };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
});

test("revisionRelation=workingTreeDiffers: ask かつ canUpdate=true(同じコミットの上の未コミットの差は align で直る)", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "workingTreeDiffers" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableMachines, ["M1Max"]);
});

test("remoteBehind と workingTreeDiffers が混在: canUpdate=true", () => {
  const a = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const b = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "workingTreeDiffers" };
  const decision = decideRemoteCompat({ machines: [a, b] });
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableMachines, ["M1Max", "M1Ultra"]);
});

test("未 push・未コミットでも更新を止めない(localDirty / revisionPublished を読まない)", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const decision = decideRemoteCompat({ machines: [machine], localDirty: true, revisionPublished: false });
  assert.equal(decision.canUpdate, true);
  assert.equal("localDirty" in decision, false);
  assert.equal("revisionUnpublished" in decision, false);
});

test("snapshotIssuer が非 null の機械は snapshotMachines に発行者つきで載る(null・空は載らない)", () => {
  const a = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "workingTreeDiffers", snapshotIssuer: "PC1" };
  const b = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "remoteBehind", snapshotIssuer: null };
  const c = { ...okMachine("M2Studio"), revisionCompatible: false, revisionRelation: "remoteBehind", snapshotIssuer: "" };
  const decision = decideRemoteCompat({ machines: [a, b, c] });
  assert.deepEqual(decision.snapshotMachines, [{ machine: "M1Max", issuer: "PC1" }]);
});

// 狙い: localIssuer の比較を外す変異で自分の分が載って落ちる / 常に除く変異で他人の分・localIssuer null の全載せが落ちる
test("自分(localIssuer)のスナップショットは snapshotMachines に載らない。localIssuer が null なら全部載せる", () => {
  const mine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "workingTreeDiffers", snapshotIssuer: "PC1" };
  const other = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "workingTreeDiffers", snapshotIssuer: "PC2" };
  const withLocal = decideRemoteCompat({ machines: [mine, other], localIssuer: "PC1" });
  assert.deepEqual(withLocal.snapshotMachines, [{ machine: "M1Ultra", issuer: "PC2" }]);
  const unknownLocal = decideRemoteCompat({ machines: [mine, other], localIssuer: null });
  assert.deepEqual(unknownLocal.snapshotMachines, [
    { machine: "M1Max", issuer: "PC1" },
    { machine: "M1Ultra", issuer: "PC2" },
  ]);
  const absent = decideRemoteCompat({ machines: [mine, other] });
  assert.equal(absent.snapshotMachines.length, 2);
});

test("revisionRelation=localBehind: ask かつ canUpdate=false・localBehindMachines に名前が入る(この機械が古い側は align で直せない)", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "localBehind" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
  assert.deepEqual(decision.localBehindMachines, ["M1Max"]);
  assert.deepEqual(decision.divergedMachines, []);
  assert.deepEqual(decision.unknownRelationMachines, []);
});

test("revisionRelation=diverged: ask かつ canUpdate=false・divergedMachines に名前が入る", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "diverged" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
  assert.deepEqual(decision.divergedMachines, ["M1Max"]);
});

test("revisionRelation=unknown: ask かつ canUpdate=false・unknownRelationMachines に名前が入る", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "unknown" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
  assert.deepEqual(decision.unknownRelationMachines, ["M1Max"]);
});

test("revisionRelation=remoteBehind(複数マシン): canUpdate=true(従来条件を満たす場合)", () => {
  const machine1 = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const machine2 = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const decision = decideRemoteCompat({ machines: [machine1, machine2] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableMachines, ["M1Max", "M1Ultra"]);
});

test("revisionRelation が null / 未設定(判定が付かなかった): 更新可能として扱う", () => {
  const machine = { ...okMachine("M1Max"), revisionCompatible: false };
  delete machine.revisionRelation;
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.equal(decision.canUpdate, true);
  assert.deepEqual(decision.updatableMachines, ["M1Max"]);
  assert.deepEqual(decision.localBehindMachines, []);
  assert.deepEqual(decision.divergedMachines, []);
  assert.deepEqual(decision.unknownRelationMachines, []);
});

test("localBehind と remoteBehind が混在: canUpdate=false(1機でも align で直らないなら全体を止める)", () => {
  const behind = { ...okMachine("M1Max"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const localBehind = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "localBehind" };
  const decision = decideRemoteCompat({ machines: [behind, localBehind] });
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
  assert.deepEqual(decision.localBehindMachines, ["M1Ultra"]);
});

test("hasXcodeSelectionError: 非空文字列だけ true", () => {
  assert.equal(hasXcodeSelectionError({ machine: "M1Max", xcodeSelectionError: "no matching Xcode found" }), true);
  assert.equal(hasXcodeSelectionError({ machine: "M1Max", xcodeSelectionError: "" }), false);
  assert.equal(hasXcodeSelectionError({ machine: "M1Max", xcodeSelectionError: null }), false);
  assert.equal(hasXcodeSelectionError({ machine: "M1Max" }), false);
});

test("xcodeSelectionError: 非 null なら toolchainCompatible が undefined でも ask かつ incompatible に入る", () => {
  // CLI 側の不変条件(xcodeSelectionError 非 null なら toolchainCompatible=false)に依存しない
  // ことを確かめる(ゲート単体で blocking へ倒す)
  const machine = { ...okMachine("M1Max"), toolchainCompatible: undefined,
                     xcodeSelectionError: "no matching Xcode; candidates: Xcode 26 (26A5xxx) at /Applications/Xcode_26.app" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.kind, "ask");
  assert.deepEqual(decision.incompatible, [machine]);
});

test("xcodeSelectionError: canUpdate=false(align では直らない)・updatableMachines は空", () => {
  const machine = { ...okMachine("M1Max"), xcodeSelectionError: "no matching Xcode found" };
  const decision = decideRemoteCompat({ machines: [machine] });
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
});

test("xcodeSelectionError と rev ズレが混在: 1機でも xcodeSelectionError があれば全体 canUpdate=false", () => {
  const selectionFailed = { ...okMachine("M1Max"), xcodeSelectionError: "no matching Xcode found" };
  const revBehind = { ...okMachine("M1Ultra"), revisionCompatible: false, revisionRelation: "remoteBehind" };
  const decision = decideRemoteCompat({ machines: [selectionFailed, revBehind] });
  assert.equal(decision.canUpdate, false);
  assert.deepEqual(decision.updatableMachines, []);
});

test("壊れた入力(machines が配列でない/report が null): proceed", () => {
  assert.deepEqual(decideRemoteCompat(null), { kind: "proceed", advisoryMachines: [] });
  assert.deepEqual(decideRemoteCompat(undefined), { kind: "proceed", advisoryMachines: [] });
  assert.deepEqual(decideRemoteCompat({ machines: "not-an-array" }), { kind: "proceed", advisoryMachines: [] });
  assert.deepEqual(decideRemoteCompat({}), { kind: "proceed", advisoryMachines: [] });
});
