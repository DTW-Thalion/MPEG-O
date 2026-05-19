/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/**
 * TTI-O Workbench Client SDK.
 *
 * <p>Client surface against {@code tti-workbench-server} v1.0.0+ -- the
 * multi-worker ObjC/GNUstep/libwebsockets daemon. Distinct from
 * {@link global.thalion.ttio.transport.TransportClient} which targets
 * the Python reference server (no auth, no {@code container_uri}, no
 * project/owner).</p>
 *
 * <p>W1 (this package and its sub-packages) ships:</p>
 * <ul>
 *   <li>{@link global.thalion.ttio.workbench.auth} -- login flow,
 *       RFC 6238 TOTP, Session token holder.</li>
 *   <li>{@link global.thalion.ttio.workbench.transport} -- workbench-aware
 *       upload + download + filtered streaming + resumable uploads
 *       over the {@code ttio-transport} WebSocket subprotocol.</li>
 * </ul>
 *
 * <p>Future Ws add: client-side cohort + pipeline + job + session
 * surfaces (W2-W4), full-coverage GUI integration via tio-browser
 * (W5), and SDK polish + crypto + federation (W6).</p>
 *
 * <p>The Python equivalent lives at {@code ttio.workbench} in the
 * {@code python/} tree. The two clients share JSON shapes and
 * acceptance criteria byte-for-byte; the W1 acceptance test asserts
 * a cross-language equivalence by uploading identical payloads from
 * both sides against a real daemon.</p>
 */
package global.thalion.ttio.workbench;
