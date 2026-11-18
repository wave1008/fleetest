// サーバーの起動失敗(ホストポートの衝突)に、同じポートを公開している**別の接頭辞の生きた控え**の持ち主を添える。
// 事実だけ使う: 自分の計画の公開ポートと他の控えの `publishedPorts` の突き合わせ(失敗ログの文言では決めない)。

import FTServices
import Foundation

enum ServicesPortConflict {
    struct Want: Equatable {
        let hostIP: String, hostPort: Int, proto: String
    }

    struct Holder: Equatable {
        let lease: ServicesLease
        let port: Int
    }

    /// 全インターフェイスへ束縛する指定(どの hostIP とも重なる)
    private static func isWildcard(_ ip: String) -> Bool { ["", "0.0.0.0", "::", "*"].contains(ip) }

    static func overlaps(_ want: Want, _ port: ServicesLease.PublishedPort) -> Bool {
        want.hostPort == port.hostPort && want.proto == port.proto
            && (want.hostIP == port.hostIP || isWildcard(want.hostIP) || isWildcard(port.hostIP))
    }

    /// `wanted` と重なる公開ポートを持つ、`myPrefix` 以外の控え(`isAlive` が真のもの)の最初の1件。控えの順は呼び手が決める
    static func holder(wanted: [Want], leases: [ServicesLease], myPrefix: String,
                       isAlive: (ServicesLease) -> Bool) -> Holder? {
        for lease in leases where lease.prefix != myPrefix && isAlive(lease) {
            for want in wanted {
                if let port = lease.publishedPorts.first(where: { overlaps(want, $0) }) {
                    return Holder(lease: lease, port: port.hostPort)
                }
            }
        }
        return nil
    }

    /// 起動失敗の文言へ添える1文
    static func hint(_ holder: Holder) -> String {
        let lease = holder.lease
        switch lease.kind {
        case .owner:
            return "port \(holder.port) is held by \(lease.holderDescription) of project \(lease.project) (profile \(lease.profile))"
                + " — stop it with `fleetest services down --project \(lease.project) --profile \(lease.profile)`"
        case .run:
            return "port \(holder.port) is held by \(lease.holderDescription) of project \(lease.project) (profile \(lease.profile))"
                + " — wait for that run to finish"
        }
    }

    /// 機械共通の索引から他の控えを読んで突き合わせる
    static func hint(wanted: [Want], myPrefix: String, home: String) -> String? {
        let leases = ServicesLeaseIndex.leaseURLs(home: home)
            .compactMap { ServicesLeaseStore.entry(at: $0)?.lease }
        guard let found = holder(wanted: wanted, leases: leases, myPrefix: myPrefix,
                                 isAlive: { !ServicesLeaseFile.isOrphan($0, isAlive: ServicesProcessIdentity.isAlive) })
        else { return nil }
        return hint(found)
    }
}
