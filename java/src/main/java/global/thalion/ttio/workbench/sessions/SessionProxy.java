/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.sessions;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Pure builders + URL constructor for the WS session-proxy attach.
 * The actual WebSocket client lives in
 * {@link SessionProxyAttach} (callback-driven via
 * {@code org.java_websocket}). The builders here have no I/O and
 * are unit-tested directly; the cross-language anchor test pins
 * Python's attach-handshake JSON against this output.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.session_proxy.build_attach_handshake} +
 * {@code session_proxy_url}.</p>
 */
public final class SessionProxy {

    public static final String SESSION_PROXY_SUBPROTOCOL = "ttio-session-proxy";

    private SessionProxy() {}

    /** Build the JSON attach-frame body. */
    public static String buildAttachHandshake(String token, String path) {
        if (token == null || token.isEmpty()) {
            throw new IllegalArgumentException("attach handshake requires `token`");
        }
        String p = (path == null || path.isEmpty()) ? "/" : path;
        if (!p.startsWith("/")) p = "/" + p;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("action", "attach");
        out.put("token",  token);
        out.put("path",   p);
        return WorkbenchJson.encode(out);
    }

    /** Build the WS proxy URL.
     *
     * @param scheme {@code "ws"} or {@code "wss"}.
     */
    public static String url(String host, int port, String sessionId, String scheme) {
        if (sessionId == null || sessionId.isEmpty()) {
            throw new IllegalArgumentException("sessionId required");
        }
        String s = scheme == null ? "ws" : scheme;
        return s + "://" + host + ":" + port + "/v1/sessions/" + sessionId + "/";
    }
}
