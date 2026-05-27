/*
 * TTIOProgressSink.h
 * TTI-O Objective-C Implementation
 *
 * Block-based progress callback type. Mirrors:
 *   Java   : global.thalion.ttio.io.ProgressSink (interface)
 *   Python : ttio.io.progress.ProgressSinkLike (callable Protocol)
 *
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_PROGRESS_SINK_H
#define TTIO_PROGRESS_SINK_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Declared In:</em> Core/TTIOProgressSink.h</p>
 *
 * <p>Progress callback fired by long-running TTI-O readers and
 * writers at meaningful chunk boundaries (per chromosome, per N
 * reads, per spectrum) &#8212; not per byte &#8212; so the
 * per-callback rate stays manageable.</p>
 *
 * <p><code>done</code> is monotonically non-decreasing within a
 * single operation. <code>total</code> is <code>-1</code> when the
 * producer cannot predict the final count (e.g. streaming reads
 * with no header); producers emit a final
 * <code>(total, total)</code> fire once the true count is known.</p>
 *
 * <p>Implementations should be cheap and non-blocking; they may
 * be invoked many times per second on a worker thread. GUI code
 * needing to update the main thread must dispatch back upstream.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Java:   <code>global.thalion.ttio.io.ProgressSink#onProgress(long,long)</code><br/>
 * Python: <code>ttio.io.progress.ProgressSinkLike</code></p>
 *
 * @since 1.3.0
 */
typedef void (^TTIOProgressBlock)(int64_t done, int64_t total);

/**
 * Returns a no-op TTIOProgressBlock. Use as a default value when
 * callers don't want progress callbacks, so emit sites can drop
 * their <code>if (progress) progress(...)</code> nil-check.
 *
 * Mirrors Java's <code>ProgressSink.discard()</code> and Python's
 * <code>ttio.io.progress.discard()</code>.
 *
 * @return A retained block that ignores its arguments.
 */
FOUNDATION_EXPORT TTIOProgressBlock TTIOProgressDiscard(void);

NS_ASSUME_NONNULL_END

#endif  /* TTIO_PROGRESS_SINK_H */
