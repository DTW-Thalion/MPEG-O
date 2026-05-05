#ifndef TTIO_JCAMP_DX_ENCODING_H
#define TTIO_JCAMP_DX_ENCODING_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOJcampDxEncoding</heading>
 *
 * <p><em>Type:</em> NS_ENUM (NSInteger)</p>
 * <p><em>Declared In:</em> Export/TTIOJcampDxEncoding.h</p>
 *
 * <p>JCAMP-DX 5.01 <code>##XYDATA=(X++(Y..Y))</code> encoding modes
 * supported by <code>TTIOJcampDxWriter</code>.</p>
 *
 * <p><code>AFFN</code> emits one free-format (X, Y) pair per line and
 * is the default. <code>PAC</code> / <code>SQZ</code> /
 * <code>DIF</code> emit the JCAMP-DX 5.01 §5.9 compressed forms;
 * equispaced X is required and a shared YFACTOR is chosen to carry
 * approximately seven significant digits of integer-scaled Y
 * precision.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Java:
 * <code>global.thalion.ttio.exporters.JcampDxEncoding</code><br/>
 * Python: <code>encoding="..."</code> keyword on
 * <code>write_*_spectrum</code></p>
 */
typedef NS_ENUM(NSInteger, TTIOJcampDxEncoding) {
    TTIOJcampDxEncodingAFFN = 0,
    TTIOJcampDxEncodingPAC  = 1,
    TTIOJcampDxEncodingSQZ  = 2,
    TTIOJcampDxEncodingDIF  = 3,
};

#endif
