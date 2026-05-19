/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.transport;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Pure JSON builders + parsers for the {@code ttio-transport} WS
 * subprotocol. No I/O. The async client classes import these to
 * construct first-frame JSON and to interpret server replies.
 * Tests reuse them without standing up a daemon.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport.handshake}. Output JSON shapes
 * are byte-identical to the Python builder so the
 * cross-language equivalence test can compare them directly.</p>
 *
 * <p>Wire shapes are defined in
 * {@code tti-workbench-server/Documentation/{upload-protocol,
 * download-protocol,auth}.md} and confirmed in
 * {@code Source/WS/TTIOWBWsUploadSession.m} +
 * {@code Source/WS/TTIOWBWsDownloadSession.m}.</p>
 */
public final class WorkbenchHandshake {

    /** Required {@code Sec-WebSocket-Protocol} value for
     *  {@code /transport}. */
    public static final String WS_SUBPROTOCOL = "ttio-transport";

    /** Filter keys the v1.0 download path validates. Mirrors the
     *  Python {@code ALLOWED_DOWNLOAD_FILTER_KEYS} set. */
    public static final Set<String> ALLOWED_DOWNLOAD_FILTER_KEYS = Set.of(
        "ms_level",
        "polarity",
        "retention_time_min",
        "retention_time_max",
        "precursor_mz_min",
        "precursor_mz_max",
        "precursor_charge",
        "max_au"
    );

    /** Output-mode strings the daemon's download handshake accepts. */
    public enum OutputMode {
        BINARY("binary"),
        STATS_ONLY("stats-only"),
        STATS_WITH_PAYLOAD("stats-with-payload");

        private final String wire;
        OutputMode(String wire) { this.wire = wire; }
        public String wire() { return wire; }

        public static OutputMode fromWire(String wire) {
            for (OutputMode m : values()) if (m.wire.equals(wire)) return m;
            throw new IllegalArgumentException("unknown output mode: " + wire);
        }
    }

    /** Server-emitted TEXT frame kind. */
    public enum ServerFrameKind { ACK, DONE, ERROR }

    /** Parsed server TEXT frame. */
    public record ServerFrame(ServerFrameKind kind, Map<String, Object> body) {}

    private WorkbenchHandshake() {}

    /** Build the upload-mode handshake JSON. */
    public static String buildUploadHandshake(
            String owner,
            String project,
            String containerUri,
            String token,
            String resumeHandle) {
        if (owner == null || owner.isEmpty())
            throw new IllegalArgumentException("upload handshake requires `owner`");
        if (project == null || project.isEmpty())
            throw new IllegalArgumentException("upload handshake requires `project`");
        if (containerUri == null || containerUri.isEmpty())
            throw new IllegalArgumentException(
                "upload handshake requires `container_uri`");

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("type",          "handshake");
        out.put("owner",         owner);
        out.put("project",       project);
        out.put("container_uri", containerUri);
        if (token         != null) out.put("token",         token);
        if (resumeHandle  != null) out.put("resume_handle", resumeHandle);
        return WorkbenchJson.encode(out);
    }

    /** Build the download-mode handshake JSON. */
    public static String buildDownloadHandshake(
            String containerUri,
            String token,
            String owner,
            OutputMode outputMode,
            Map<String, Object> filter,
            int maxAu) {
        if (containerUri == null || containerUri.isEmpty())
            throw new IllegalArgumentException(
                "download handshake requires `container_uri`");
        if (maxAu < 0)
            throw new IllegalArgumentException("max_au must be >= 0");
        if (filter != null) {
            for (String key : filter.keySet()) {
                if (!ALLOWED_DOWNLOAD_FILTER_KEYS.contains(key)) {
                    throw new IllegalArgumentException(
                        "unknown filter key '" + key + "'; allowed: " +
                        ALLOWED_DOWNLOAD_FILTER_KEYS);
                }
            }
        }
        OutputMode mode = outputMode == null ? OutputMode.BINARY : outputMode;

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("type",          "handshake");
        out.put("mode",          "download");
        out.put("container_uri", containerUri);
        out.put("output_mode",   mode.wire());
        if (token         != null) out.put("token", token);
        if (owner         != null) out.put("owner", owner);
        if (maxAu          > 0)    out.put("max_au", (long) maxAu);
        if (filter != null && !filter.isEmpty()) out.put("filter", filter);
        return WorkbenchJson.encode(out);
    }

    /** Parse a server TEXT frame into kind + body. */
    @SuppressWarnings("unchecked")
    public static ServerFrame parseServerFrame(String raw) {
        Object parsed = WorkbenchJson.parse(raw);
        if (!(parsed instanceof Map<?, ?> mRaw)) {
            throw new IllegalArgumentException(
                "server frame not an object: " + raw);
        }
        Map<String, Object> body = (Map<String, Object>) mRaw;
        Object t = body.get("type");
        if (!(t instanceof String s)) {
            throw new IllegalArgumentException(
                "server frame missing string `type`: " + raw);
        }
        ServerFrameKind kind;
        switch (s) {
            case "ack":   kind = ServerFrameKind.ACK;   break;
            case "done":  kind = ServerFrameKind.DONE;  break;
            case "error": kind = ServerFrameKind.ERROR; break;
            default: throw new IllegalArgumentException(
                "unknown server frame type '" + s + "'");
        }
        return new ServerFrame(kind, body);
    }
}
