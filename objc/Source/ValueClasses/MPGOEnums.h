#ifndef MPGO_ENUMS_H
#define MPGO_ENUMS_H

#import <Foundation/Foundation.h>

/*
 * Cross-language equivalents:
 *   Python: mpeg_o.enums
 *   Java:   com.dtwthalion.mpgo.Enums
 *
 * Declaration order in each ObjC NS_ENUM is authoritative; Python's
 * IntEnum values and Java's enum declaration order must match.
 *
 * API status: Stable.
 */

typedef NS_ENUM(NSUInteger, MPGOSamplingMode) {
    MPGOSamplingModeUniform = 0,
    MPGOSamplingModeNonUniform
};

typedef NS_ENUM(NSUInteger, MPGOPrecision) {
    MPGOPrecisionFloat32 = 0,
    MPGOPrecisionFloat64,
    MPGOPrecisionInt32,
    MPGOPrecisionInt64,
    MPGOPrecisionUInt32,
    MPGOPrecisionComplex128
};

typedef NS_ENUM(NSUInteger, MPGOCompression) {
    MPGOCompressionNone = 0,
    MPGOCompressionZlib,
    MPGOCompressionLZ4,
    MPGOCompressionNumpressDelta  // v0.3 M21: fixed-point + first-difference
};

typedef NS_ENUM(NSUInteger, MPGOByteOrder) {
    MPGOByteOrderLittleEndian = 0,
    MPGOByteOrderBigEndian
};

typedef NS_ENUM(NSInteger, MPGOPolarity) {
    MPGOPolarityUnknown  =  0,
    MPGOPolarityPositive =  1,
    MPGOPolarityNegative = -1
};

typedef NS_ENUM(NSUInteger, MPGOChromatogramType) {
    MPGOChromatogramTypeTIC = 0,
    MPGOChromatogramTypeXIC,
    MPGOChromatogramTypeSRM
};

typedef NS_ENUM(NSUInteger, MPGOAcquisitionMode) {
    MPGOAcquisitionModeMS1DDA = 0,
    MPGOAcquisitionModeMS2DDA,
    MPGOAcquisitionModeDIA,
    MPGOAcquisitionModeSRM,
    MPGOAcquisitionMode1DNMR,
    MPGOAcquisitionMode2DNMR,
    MPGOAcquisitionModeImaging
};

typedef NS_ENUM(NSUInteger, MPGOEncryptionLevel) {
    MPGOEncryptionLevelNone = 0,
    MPGOEncryptionLevelDatasetGroup,
    MPGOEncryptionLevelDataset,
    MPGOEncryptionLevelDescriptorStream,
    MPGOEncryptionLevelAccessUnit
};

#endif /* MPGO_ENUMS_H */
