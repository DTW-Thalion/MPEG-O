/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Internal extension to TTIOTransportReader. Exposes the
 * inspection-only accessor used by the forward-compat skip-unknown
 * tests (TestTransportReaderSkipUnknown.m). Not part of the public
 * TTIO API — not re-exported via TTIO.h.
 *
 * Cross-language parity: Java
 * ``TransportReader.recordsForTest`` (package-private), Python
 * ``TransportReader.records_for_test`` (underscore-not-but-internal).
 */
#ifndef TTIO_TRANSPORT_READER_INTERNAL_H
#define TTIO_TRANSPORT_READER_INTERNAL_H

#import "TTIOTransportReader.h"

NS_ASSUME_NONNULL_BEGIN

@interface TTIOTransportReader (Internal)

/** Test-only inspection accessor. Synonym for
 *  ``-readAllPacketsWithError:`` that swallows the error and returns
 *  ``nil`` on failure. Production consumers should call the public
 *  ``-readAllPacketsWithError:`` so they see the underlying
 *  ``NSError``. */
- (nullable NSArray<TTIOTransportPacketRecord *> *)recordsForTest;

@end

NS_ASSUME_NONNULL_END

#endif
