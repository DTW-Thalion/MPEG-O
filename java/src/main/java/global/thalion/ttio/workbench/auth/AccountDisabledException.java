/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.auth;

/**
 * HTTP 423 on login -- the user row has a non-null {@code disabled_at}
 * column. Resolution: the administrator re-enables the account via
 * the admin API (S5 surface) or by direct DB edit on legacy v1.0
 * deployments where the admin endpoint is not yet wired.
 */
public final class AccountDisabledException extends WorkbenchAuthException {

    public AccountDisabledException(String message) {
        super(message);
    }
}
