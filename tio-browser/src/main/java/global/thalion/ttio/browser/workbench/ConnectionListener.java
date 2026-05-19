/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

/**
 * Notified whenever {@link ConnectionManager}'s state changes.
 *
 * <p>Always invoked on the calling thread of
 * {@code ConnectionManager.connect()} / {@code disconnect()}.
 * Callers wanting JavaFX-thread delivery should wrap the listener
 * in {@code javafx.application.Platform.runLater}.</p>
 */
@FunctionalInterface
public interface ConnectionListener {

    /** Fired on every transition. {@code message} is non-null for
     *  {@link ConnectionState#FAILED}, otherwise empty. */
    void onStateChanged(ConnectionState state, String message);
}
