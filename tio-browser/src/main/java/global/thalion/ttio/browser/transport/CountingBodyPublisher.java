/*
 * tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.transport;

import java.net.http.HttpRequest;
import java.nio.ByteBuffer;
import java.util.concurrent.Flow;
import java.util.function.LongConsumer;

/**
 * Wraps a {@link HttpRequest.BodyPublisher} (typically
 * {@code BodyPublishers.ofFile(path)}) and reports running byte
 * counts as ByteBuffers flow downstream to the HTTP client.
 *
 * <p>Used by {@link TisHttpUploader} to surface mid-stream upload
 * progress without losing the streaming nature of the underlying
 * file publisher (no in-memory buffering of the whole file).</p>
 */
public final class CountingBodyPublisher implements HttpRequest.BodyPublisher {

    private final HttpRequest.BodyPublisher delegate;
    private final LongConsumer onBytes;

    public CountingBodyPublisher(HttpRequest.BodyPublisher delegate,
                                   LongConsumer onBytes) {
        this.delegate = delegate;
        this.onBytes  = onBytes;
    }

    @Override
    public long contentLength() { return delegate.contentLength(); }

    @Override
    public void subscribe(Flow.Subscriber<? super ByteBuffer> subscriber) {
        delegate.subscribe(new CountingSubscriber(subscriber, onBytes));
    }

    private static final class CountingSubscriber
            implements Flow.Subscriber<ByteBuffer> {
        private final Flow.Subscriber<? super ByteBuffer> downstream;
        private final LongConsumer onBytes;
        private long count;

        CountingSubscriber(Flow.Subscriber<? super ByteBuffer> downstream,
                           LongConsumer onBytes) {
            this.downstream = downstream;
            this.onBytes    = onBytes;
        }

        @Override public void onSubscribe(Flow.Subscription s) { downstream.onSubscribe(s); }
        @Override public void onNext(ByteBuffer item) {
            count += item.remaining();
            if (onBytes != null) onBytes.accept(count);
            downstream.onNext(item);
        }
        @Override public void onError(Throwable t) { downstream.onError(t); }
        @Override public void onComplete() { downstream.onComplete(); }
    }
}
