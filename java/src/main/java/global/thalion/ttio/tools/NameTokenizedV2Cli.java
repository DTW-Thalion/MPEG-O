/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.NameTokenizerV2;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * NAME_TOKENIZED v2 CLI for cross-language byte-equality tests.
 *
 * <p>Reads ASCII read names (one per line) from {@code arg[0]}, encodes via
 * {@link NameTokenizerV2}, writes the encoded blob to {@code arg[1]}.
 *
 * <p>Mirrors the ObjC {@code TtioNameTokV2Cli} and the Python
 * {@code python -m ttio.tools.name_tok_v2_cli} entry. All three CLIs read the
 * same line-delimited input file so the Task 11 cross-lang gate can compare
 * outputs byte-for-byte.
 */
public class NameTokenizedV2Cli {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Usage: NameTokenizedV2Cli <names.txt> <out.bin>");
            System.exit(1);
        }
        List<String> names = new ArrayList<>();
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            if (!line.isEmpty()) names.add(line);
        }
        byte[] blob = NameTokenizerV2.encode(names);
        Files.write(Path.of(args[1]), blob);
        System.out.printf("encoded %d names -> %d bytes%n", names.size(), blob.length);
    }
}
