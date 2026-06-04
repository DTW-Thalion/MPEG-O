/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package global.thalion.ttio.exporters;

import java.util.List;

/** One export-format entry: a canonical key paired with its display label,
 *  filename extensions, optional external tool, and the {@link Writer} that
 *  serializes one layer of an opened dataset to an output file.
 *
 *  <p>Mirrors Python {@code ttio.exporters.registry.ExportSpec}.
 *
 *  @param key          canonical lowercase key (e.g. {@code "mzml"})
 *  @param displayName  GUI-matching label (e.g. {@code "mzML"})
 *  @param extensions   recognised filename extensions (e.g. {@code .mzML})
 *  @param requiredTool external binary, or {@code null}
 *  @param writer       serializes one layer -&gt; output
 */
public record ExportSpec(String key, String displayName,
                         List<String> extensions, String requiredTool,
                         Writer writer) {
}
