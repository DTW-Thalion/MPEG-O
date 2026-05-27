/*
 * TTIOProgressSink.m
 * TTI-O Objective-C Implementation
 *
 * Declared In: Core/TTIOProgressSink.h
 *
 * Implements the discard sink: a singleton no-op block returned by
 * value (blocks are reference-counted; ARC/MRR friendly).
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOProgressSink.h"

TTIOProgressBlock TTIOProgressDiscard(void)
{
    // Returning a literal block here gives each caller an autoreleased
    // copy; cheap (no allocations under MRR/ARC for a no-capture
    // block) and avoids retaining a shared singleton across runtimes.
    return ^(int64_t done, int64_t total) {
        (void)done;
        (void)total;
    };
}
