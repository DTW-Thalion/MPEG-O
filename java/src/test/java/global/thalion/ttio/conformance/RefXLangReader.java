/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.conformance;

import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * tio-browser Phase 0 Task 0.6 — standalone CLI helper that opens a
 * {@code .tio}, reads {@link SpectralDataset#references()}, and prints
 * a single line of canonical JSON to stdout:
 *
 * <pre>
 * {"&lt;uri&gt;": {"_md5": "&lt;hex&gt;",
 *               "&lt;chrom&gt;": "&lt;lowercase-hex-bytes&gt;", ...}, ...}
 * </pre>
 *
 * <p>The {@code _md5} key (underscore prefix puts it before any
 * chromosome name in alphabetical order) carries the {@code @md5}
 * attribute round-tripped verbatim from disk, so cross-language byte
 * parity on the MD5 attribute is exercised in addition to the
 * chromosome-content parity.</p>
 *
 * <p>URIs and chromosome names are emitted in alphabetical order so
 * the output is byte-identical to what the Python and ObjC readers
 * produce (dict-equality in pytest is order-independent, but stable
 * key order makes log diffs trivial).
 *
 * <p>Usage: {@code java ... RefXLangReader <in.tio>}.
 */
public final class RefXLangReader {

    private RefXLangReader() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: RefXLangReader <in.tio>");
            System.exit(2);
        }
        try (SpectralDataset ds = SpectralDataset.open(args[0])) {
            Map<String, ReferenceImport> refs = ds.references();
            List<String> uris = new ArrayList<>(refs.keySet());
            Collections.sort(uris);

            StringBuilder sb = new StringBuilder("{");
            boolean firstUri = true;
            for (String uri : uris) {
                if (!firstUri) sb.append(",");
                firstUri = false;
                sb.append('"').append(uri).append("\":{");
                ReferenceImport r = refs.get(uri);
                // _md5 emitted first (sorts before any chromosome name).
                sb.append("\"_md5\":\"").append(r.md5Hex()).append("\"");
                List<String> chroms = new ArrayList<>(r.chromosomes());
                Collections.sort(chroms);
                for (String chrom : chroms) {
                    sb.append(",");
                    byte[] bytes = r.chromosome(chrom);
                    sb.append('"').append(chrom).append("\":\"");
                    for (byte b : bytes) {
                        int v = b & 0xff;
                        sb.append(Character.forDigit((v >>> 4) & 0xf, 16));
                        sb.append(Character.forDigit(v & 0xf, 16));
                    }
                    sb.append('"');
                }
                sb.append("}");
            }
            sb.append("}");
            System.out.println(sb);
        }
    }
}
