/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.importers;

import java.util.List;

/** One import-format entry: a canonical key paired with its display label,
 *  filename extensions, optional external tool, and the {@link Reader} that
 *  parses inputs into an {@link ImportedDataset}.
 *
 *  <p>Mirrors Python {@code ttio.importers.registry.FormatSpec}.
 *
 *  @param key          canonical lowercase key (e.g. {@code "mzml"})
 *  @param displayName  GUI-matching label (e.g. {@code "mzML"})
 *  @param extensions   recognised filename extensions (e.g. {@code .mzML})
 *  @param requiredTool external binary, or {@code null}
 *  @param reader       parses inputs -&gt; {@link ImportedDataset}
 */
public record FormatSpec(String key, String displayName,
                         List<String> extensions, String requiredTool,
                         Reader reader) {
}
