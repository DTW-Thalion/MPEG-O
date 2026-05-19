/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

/**
 * State of the GUI's workbench connection.
 *
 * <p>The four values map onto the user-visible status indicator
 * colours: {@link #DISCONNECTED} (red), {@link #CONNECTING}
 * (yellow), {@link #CONNECTED} (green), {@link #FAILED} (red with
 * a tooltip carrying the last error message).</p>
 *
 * <p>The state machine is intentionally narrow: {@code DISCONNECTED
 * -> CONNECTING -> (CONNECTED | FAILED)}, and any state can drop
 * back to {@code DISCONNECTED} via {@code disconnect()}. There is
 * no automatic retry from {@code FAILED} -- the operator must
 * re-open the login dialog.</p>
 */
public enum ConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    FAILED
}
