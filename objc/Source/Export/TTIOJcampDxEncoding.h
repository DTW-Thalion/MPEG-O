#ifndef TTIO_JCAMP_DX_ENCODING_H
#define TTIO_JCAMP_DX_ENCODING_H

#import <Foundation/Foundation.h>

/**
 * JCAMP-DX 5.01 `##XYDATA=(X++(Y..Y))` encoding modes supported by
 * `TTIOJcampDxWriter`.
 *
 * `AFFN` emits one free-format (X, Y) pair per line — the default
 * and the only mode available prior to M76. `PAC` / `SQZ` / `DIF`
 * emit the JCAMP-DX 5.01 §5.9 compressed forms; equispaced X is
 * required and a shared YFACTOR is chosen to carry ~7 significant
 * digits of integer-scaled Y precision.
 *
 * Cross-language equivalents:
 *   Java:    global.thalion.ttio.exporters.JcampDxEncoding
 *   Python:  encoding="..." keyword on write_*_spectrum
 */
typedef NS_ENUM(NSInteger, TTIOJcampDxEncoding) {
    TTIOJcampDxEncodingAFFN = 0,
    TTIOJcampDxEncodingPAC  = 1,
    TTIOJcampDxEncodingSQZ  = 2,
    TTIOJcampDxEncodingDIF  = 3,
};

#endif
