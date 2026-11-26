package com.example.ftbridge;

import android.app.UiAutomation;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * POST /semanticsorder の中身。直近の /snapshot の木の仮想ノードについて、Flutter の VM サービスから
 * セマンティクスのダンプ(逆ヒットテスト順)を素の HTTP GET で取って返す。**読むだけ**なので1回撃ち直してよい。
 * ブリッジはダンプを解析しない(並びの解析はホストの FTCore `FlutterSemanticsDump`。Sources/FTCore/SemanticsPaintOrder.swift)。
 * 契約: 成功 {dump, nodes:[{ref, semanticsId, cx, cy}]} / 答えられない {reason}(語彙は REASON_*)。
 */
final class FlutterSemanticsOrder {
    private FlutterSemanticsOrder() {}

    static final String REASON_NO_SNAPSHOT = "no-snapshot";
    static final String REASON_NO_VIRTUAL_NODES = "no-virtual-nodes";
    static final String REASON_MULTIPLE_HOSTS = "multiple-hosts";
    static final String REASON_NO_PID = "no-pid";
    static final String REASON_NO_VM_SERVICE = "no-vm-service";
    static final String REASON_DUMP_FAILED = "dump-failed";
    static final String REASON_TIMEOUT = "timeout";
    static final String REASON_EMPTY_DUMP = "empty-dump";

    /** 1回の HTTP の接続・読みそれぞれの上限(ms)。段0のスクロールの最中の最大 50.1ms の約10倍。尽きたら timeout を返す(ホストは今の挙動のまま) */
    private static final int HTTP_TIMEOUT_MS = 500;

    private static final Pattern VM_URI = Pattern.compile(
            "The Dart VM service is listening on (http://127\\.0\\.0\\.1:\\d+/[^\\s]*/)");

    // pid ごとの控え(ログは流れて消える・isolate は同じ pid の間は変わらない)。同時リクエストに備え cacheLock で守る
    private static final Object cacheLock = new Object();
    private static final Map<String, String> uriByPid = new HashMap<>();
    private static final Map<String, String> isolateByPid = new HashMap<>();

    private static final class Failure extends Exception {
        final String reason;
        Failure(String reason) { super(reason); this.reason = reason; }
    }

    static JSONObject answer(UiAutomation ua, String pkg, Map<Integer, Integer> virtualIds,
                             Map<Integer, Integer> hostKeys, Map<Integer, double[]> centers) throws JSONException {
        if (pkg == null) return reason(REASON_NO_SNAPSHOT);
        if (virtualIds.isEmpty()) return reason(REASON_NO_VIRTUAL_NODES);
        Set<Integer> hosts = new HashSet<>(hostKeys.values());
        if (hosts.size() > 1) return reason(REASON_MULTIPLE_HOSTS);
        String dump;
        try {
            dump = fetchDump(ua, pkg);
        } catch (Failure f) {
            return reason(f.reason);
        }
        if (dump.trim().isEmpty()) return reason(REASON_EMPTY_DUMP);
        JSONArray nodes = new JSONArray();
        for (int ref : new TreeSet<>(virtualIds.keySet())) {
            double[] c = centers.get(ref);
            if (c == null) continue;
            JSONObject n = new JSONObject();
            n.put("ref", ref);
            n.put("semanticsId", virtualIds.get(ref));
            n.put("cx", c[0]);
            n.put("cy", c[1]);
            nodes.put(n);
        }
        JSONObject o = new JSONObject();
        o.put("dump", dump);
        o.put("nodes", nodes);
        return o;
    }

    private static JSONObject reason(String reason) throws JSONException {
        return new JSONObject().put("reason", reason);
    }

    /** 控えで1回・失敗したら控えを捨ててやり直しで1回(timeout はやり直さない = 上限を2倍にしない) */
    private static String fetchDump(UiAutomation ua, String pkg) throws Failure {
        String pid = pidOf(ua, pkg);
        try {
            return fetchOnce(ua, pid);
        } catch (Failure first) {
            if (REASON_TIMEOUT.equals(first.reason) || REASON_NO_VM_SERVICE.equals(first.reason)) throw first;
            synchronized (cacheLock) {
                uriByPid.remove(pid);
                isolateByPid.remove(pid);
            }
            return fetchOnce(ua, pid);
        }
    }

    private static String pidOf(UiAutomation ua, String pkg) throws Failure {
        String out;
        try {
            out = BridgeRouter.rawShell(ua, "pidof " + pkg).trim();
        } catch (RuntimeException e) {
            throw new Failure(REASON_NO_PID);
        }
        if (!out.matches("\\d+")) throw new Failure(REASON_NO_PID);
        return out;
    }

    private static String fetchOnce(UiAutomation ua, String pid) throws Failure {
        String uri;
        synchronized (cacheLock) { uri = uriByPid.get(pid); }
        if (uri == null) {
            String log;
            try {
                log = BridgeRouter.rawShell(ua, "logcat -d --pid=" + pid + " -s flutter:I");
            } catch (RuntimeException e) {
                throw new Failure(REASON_DUMP_FAILED);
            }
            Matcher m = VM_URI.matcher(log);
            while (m.find()) uri = m.group(1);
            if (uri == null) throw new Failure(REASON_NO_VM_SERVICE);
            synchronized (cacheLock) { uriByPid.put(pid, uri); }
        }
        String isolate;
        synchronized (cacheLock) { isolate = isolateByPid.get(pid); }
        if (isolate != null) return dumpOf(uri, isolate);
        JSONArray isolates = isolates(uri);
        Failure last = new Failure(REASON_DUMP_FAILED);
        // name が main を先に、無ければ順に
        for (int pass = 0; pass < 2; pass++) {
            for (int i = 0; i < isolates.length(); i++) {
                JSONObject iso = isolates.optJSONObject(i);
                if (iso == null) continue;
                boolean isMain = "main".equals(iso.optString("name"));
                if (isMain != (pass == 0)) continue;
                String id = iso.optString("id", "");
                if (id.isEmpty()) continue;
                try {
                    String dump = dumpOf(uri, id);
                    synchronized (cacheLock) { isolateByPid.put(pid, id); }
                    return dump;
                } catch (Failure f) {
                    if (REASON_TIMEOUT.equals(f.reason)) throw f;
                    last = f;
                }
            }
        }
        throw last;
    }

    private static JSONArray isolates(String uri) throws Failure {
        try {
            JSONObject result = new JSONObject(get(uri + "getVM")).getJSONObject("result");
            return result.getJSONArray("isolates");
        } catch (JSONException e) {
            throw new Failure(REASON_DUMP_FAILED);
        }
    }

    private static String dumpOf(String uri, String isolateId) throws Failure {
        try {
            String url = uri + "ext.flutter.debugDumpSemanticsTreeInInverseHitTestOrder?isolateId="
                    + URLEncoder.encode(isolateId, "UTF-8");
            JSONObject result = new JSONObject(get(url)).getJSONObject("result");
            return result.getString("data");
        } catch (JSONException | java.io.UnsupportedEncodingException e) {
            throw new Failure(REASON_DUMP_FAILED);
        }
    }

    private static String get(String url) throws Failure {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setConnectTimeout(HTTP_TIMEOUT_MS);
            conn.setReadTimeout(HTTP_TIMEOUT_MS);
            conn.setRequestMethod("GET");
            if (conn.getResponseCode() != 200) throw new Failure(REASON_DUMP_FAILED);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = conn.getInputStream()) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
            return out.toString("UTF-8");
        } catch (SocketTimeoutException e) {
            throw new Failure(REASON_TIMEOUT);
        } catch (java.io.IOException e) {
            throw new Failure(REASON_DUMP_FAILED);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
