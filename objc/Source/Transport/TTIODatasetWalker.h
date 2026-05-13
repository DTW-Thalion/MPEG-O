/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_DATASET_WALKER_H
#define TTIO_DATASET_WALKER_H

#import <Foundation/Foundation.h>
#import "TTIOAccessUnit.h"

@class TTIOSpectralDataset;
@class TTIOAUFilter;
@class TTIODatasetWalker;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject (informal)</p>
 * <p><em>Declared In:</em> Transport/TTIODatasetWalker.h</p>
 *
 * <p>Visitor protocol invoked by <code>TTIODatasetWalker</code> for
 * every transport-stream event a filtered dataset produces. All
 * methods are optional — visitors implement only the events they
 * care about.</p>
 *
 * <p>Event order:</p>
 *
 * <ol>
 *  <li><code>-walker:visitStreamHeader…</code> once.</li>
 *  <li><code>-walker:visitDatasetHeader…</code> per matched dataset
 *      (in iteration order: MS runs sorted by name, then genomic
 *      runs sorted by name).</li>
 *  <li><code>-walker:visitAccessUnit…</code> per matched AU.</li>
 *  <li><code>-walker:visitEndOfDataset…</code> per matched dataset.</li>
 *  <li><code>-walker:visitEndOfStream</code> once.</li>
 * </ol>
 *
 * <p>Implementations of two well-known visitors live in libTTIO:</p>
 * <ul>
 *  <li><strong>Encoding visitor</strong>: wraps a
 *      <code>TTIOTransportWriter</code> to emit each event as the
 *      corresponding transport packet. Used by
 *      <code>TTIOTransportServer</code> for filtered WS downloads
 *      and by the workbench server's S3 binary-mode session.</li>
 *  <li><strong>Stats visitor</strong>: ignores everything except
 *      <code>-walker:visitAccessUnit…</code> and emits
 *      <code>TTIOAUStats</code> JSON per AU. Used by the workbench
 *      server's <code>stats-only</code> and
 *      <code>stats-with-payload</code> modes.</li>
 * </ul>
 */
@protocol TTIOTransportEventVisitor <NSObject>
@optional
- (void)walker:(TTIODatasetWalker *)walker
visitStreamHeaderWithFormatVersion:(NSString *)formatVersion
                              title:(NSString *)title
                   isaInvestigation:(NSString *)isaInvestigation
                           features:(NSArray<NSString *> *)features
                         nDatasets:(uint16_t)nDatasets;

- (void)walker:(TTIODatasetWalker *)walker
visitDatasetHeaderWithDatasetId:(uint16_t)datasetId
                            name:(NSString *)name
                 acquisitionMode:(uint8_t)acquisitionMode
                   spectrumClass:(NSString *)spectrumClass
                    channelNames:(NSArray<NSString *> *)channelNames
                  instrumentJSON:(NSString *)instrumentJSON
                expectedAUCount:(uint32_t)expectedAUCount;

- (void)walker:(TTIODatasetWalker *)walker
 visitAccessUnit:(TTIOAccessUnit *)au
       datasetId:(uint16_t)datasetId
      auSequence:(uint32_t)auSequence;

- (void)walker:(TTIODatasetWalker *)walker
visitEndOfDatasetWithDatasetId:(uint16_t)datasetId
                finalAUSequence:(uint32_t)finalAUSequence;

- (void)walkerVisitEndOfStream:(TTIODatasetWalker *)walker;
@end


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIODatasetWalker.h</p>
 *
 * <p>Walks a <code>TTIOSpectralDataset</code> packet-event by
 * packet-event, applying an optional <code>TTIOAUFilter</code> and
 * dispatching to a visitor. Stateless once constructed; safe to
 * reuse across walks.</p>
 *
 * <p>Walking order matches the transport-stream emission order
 * baked into <code>TTIOTransportWriter writeDataset:</code> so the
 * sequence of visitor calls is byte-equivalent to the canonical
 * dataset emission when the visitor is the encoding one.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python:
 *   <code>ttio.transport.walker.walk_dataset</code> (generator)<br/>
 * Java:
 *   <code>global.thalion.ttio.transport.DatasetWalker</code></p>
 */
@interface TTIODatasetWalker : NSObject

/// Walks the dataset event-by-event. Iterates every MS run then
/// every genomic run (sorted by name), applying `filter` to each
/// constructed AU and dispatching events to `visitor`. The walker
/// instance is stateless across walks — reuse freely.
- (BOOL)walkDataset:(TTIOSpectralDataset *)dataset
              filter:(nullable TTIOAUFilter *)filter
             visitor:(id<TTIOTransportEventVisitor>)visitor
               error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
