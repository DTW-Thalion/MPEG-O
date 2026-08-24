/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.assembly;

/**
 * One GFA {@code L} record. {@code tags} is the verbatim tab-joined
 * remainder, {@code ""} when none.
 *
 * <p><b>Cross-language equivalents:</b> Objective-C
 * {@code TTIOGraphLink}, Python {@code ttio.assembly.GraphLink}.</p>
 */
public record GraphLink(String fromSegment, String fromOrient,
                        String toSegment, String toOrient,
                        String overlap, String tags) {}
