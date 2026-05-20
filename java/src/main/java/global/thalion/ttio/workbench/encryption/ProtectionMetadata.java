/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.encryption;

import global.thalion.ttio.workbench.WorkbenchJson;

import java.util.Base64;
import java.util.Map;

/**
 * Upload-path protection descriptor for the workbench client.
 *
 * <p>Mirrors the transport ProtectionMetadata packet
 * ({@code global.thalion.ttio.transport.ProtectionMetadata}):
 * {@code cipher_suite} / {@code kek_algorithm} / {@code wrapped_dek}
 * / {@code signature_algorithm} / {@code public_key}. This client-side
 * variant adds a canonical JSON form used as a cross-language anchor.</p>
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.encryption.ProtectionMetadata}. {@link #toJson()}
 * is byte-identical to the Python {@code to_json()} (sorted keys,
 * compact separators, standard base64), so a fixed BYOK metadata
 * serialises identically across languages.</p>
 */
public final class ProtectionMetadata {

    public final String cipherSuite;
    public final String kekAlgorithm;
    public final byte[] wrappedDek;
    public final String signatureAlgorithm;
    public final byte[] publicKey;

    public ProtectionMetadata(String cipherSuite, String kekAlgorithm,
                                byte[] wrappedDek, String signatureAlgorithm,
                                byte[] publicKey) {
        this.cipherSuite = cipherSuite;
        this.kekAlgorithm = kekAlgorithm;
        this.wrappedDek = wrappedDek;
        this.signatureAlgorithm = signatureAlgorithm;
        this.publicKey = publicKey;
    }

    /** Canonical JSON: sorted keys, compact separators, standard base64
     *  for byte blobs. Byte-identical to the Python {@code to_json()}. */
    public String toJson() {
        Base64.Encoder b64 = Base64.getEncoder();
        // Alphabetical key order: cipher_suite, kek_algorithm,
        // public_key, signature_algorithm, wrapped_dek.
        return "{"
            + "\"cipher_suite\":" + jsonString(cipherSuite) + ","
            + "\"kek_algorithm\":" + jsonString(kekAlgorithm) + ","
            + "\"public_key\":\"" + b64.encodeToString(publicKey) + "\","
            + "\"signature_algorithm\":" + jsonString(signatureAlgorithm) + ","
            + "\"wrapped_dek\":\"" + b64.encodeToString(wrappedDek) + "\""
            + "}";
    }

    @SuppressWarnings("unchecked")
    public static ProtectionMetadata fromJson(String text) {
        Map<String, Object> m = (Map<String, Object>) WorkbenchJson.parse(text);
        Base64.Decoder b64 = Base64.getDecoder();
        return new ProtectionMetadata(
            (String) m.get("cipher_suite"),
            (String) m.get("kek_algorithm"),
            b64.decode((String) m.get("wrapped_dek")),
            (String) m.get("signature_algorithm"),
            b64.decode((String) m.get("public_key")));
    }

    private static String jsonString(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"'  -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                default   -> sb.append(c);
            }
        }
        return sb.append('"').toString();
    }
}
