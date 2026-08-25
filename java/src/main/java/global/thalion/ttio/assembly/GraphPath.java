/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.assembly;

/**
 * One GFA {@code P} record. {@code tags} is the verbatim tab-joined
 * remainder, {@code ""} when none.
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGraphPath}, Python {@code ttio.assembly.GraphPath}.</p>
 */
public record GraphPath(String name, String segmentList,
                        String overlaps, String tags) {}
