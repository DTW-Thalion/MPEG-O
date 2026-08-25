/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.assembly;

/**
 * One GFA {@code S} record. {@code sequence} is {@code null} for a
 * {@code *} (missing) sequence; {@code tags} is the verbatim
 * tab-joined remainder, {@code ""} when none.
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGraphSegment}, Python {@code ttio.assembly.GraphSegment}.</p>
 */
public record GraphSegment(String name, byte[] sequence, String tags) {}
