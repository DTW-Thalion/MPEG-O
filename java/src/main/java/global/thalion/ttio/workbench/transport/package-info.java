/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/**
 * Workbench-aware WebSocket transport.
 *
 * <p>Speaks the {@code ttio-transport} WS subprotocol against
 * {@code tti-workbench-server} v1.0.0+. Distinct from
 * {@link global.thalion.ttio.transport.TransportClient} which
 * targets the Python reference server (no auth, no
 * {@code container_uri}, no project/owner).</p>
 *
 * <p>Entry points:</p>
 * <ul>
 *   <li>{@link global.thalion.ttio.workbench.transport.WorkbenchTransportClient}
 *       -- end-to-end upload + download against a v1.0 daemon.</li>
 *   <li>{@link global.thalion.ttio.workbench.transport.WorkbenchHandshake}
 *       -- pure JSON builders / parsers for the wire frames.
 *       No I/O; reused by tests + tooling.</li>
 *   <li>{@link global.thalion.ttio.workbench.transport.ResumeState}
 *       -- resume bookkeeping for partial uploads.</li>
 * </ul>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.transport}. The JSON shapes on the wire are
 * byte-identical to the Python builder so the cross-language
 * equivalence test can compare them directly.</p>
 */
package global.thalion.ttio.workbench.transport;
