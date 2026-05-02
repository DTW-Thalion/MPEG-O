#ifndef TTIO_ENUMS_H
#define TTIO_ENUMS_H

#import <Foundation/Foundation.h>

/*
 * Cross-language equivalents:
 *   Python: ttio.enums
 *   Java:   global.thalion.ttio.Enums
 *
 * Declaration order in each ObjC NS_ENUM is authoritative; Python's
 * IntEnum values and Java's enum declaration order must match.
 *
 * API status: Stable.
 */

typedef NS_ENUM(NSUInteger, TTIOSamplingMode) {
    TTIOSamplingModeUniform = 0,
    TTIOSamplingModeNonUniform
};

/**
 * Numeric precision of a signal buffer.
 *
 * Appendix B Gap 7: TTIOPrecision is a pure enum. The HDF5 type
 * mapping (H5T_NATIVE_DOUBLE &c.) lives in the HDF5 provider layer
 * so non-HDF5 providers (SQLite, in-memory, future Zarr) can use
 * this enum without pulling the HDF5 library onto the link graph.
 * Cross-language equivalents: Python ttio.enums.Precision, Java
 * global.thalion.ttio.Enums.Precision.
 */
typedef NS_ENUM(NSUInteger, TTIOPrecision) {
    TTIOPrecisionFloat32 = 0,
    TTIOPrecisionFloat64,
    TTIOPrecisionInt32,
    TTIOPrecisionInt64,
    TTIOPrecisionUInt32,
    TTIOPrecisionComplex128,
    TTIOPrecisionUInt8,       // v0.11 M79: genomic quality scores + packed bases
    TTIOPrecisionUInt16 = 7,  // v1.2.0 L1 (Task #82): genomic_index/chromosome_ids
    TTIOPrecisionUInt64 = 9   // v0.11 M82: genomic index offsets (8 reserved for INT8)
};

typedef NS_ENUM(NSUInteger, TTIOCompression) {
    TTIOCompressionNone = 0,
    TTIOCompressionZlib,
    TTIOCompressionLZ4,
    TTIOCompressionNumpressDelta,    // v0.3 M21: fixed-point + first-difference
    TTIOCompressionRansOrder0,       // v0.11 M79: rANS order-0 entropy coder
    TTIOCompressionRansOrder1,       // v0.11 M79: rANS order-1 entropy coder
    TTIOCompressionBasePack,         // v0.11 M79: 2-bit ACGT packed bases
    TTIOCompressionQualityBinned,    // v0.11 M79: Illumina-style quality binning
    TTIOCompressionNameTokenized,    // v0.11 M79: read-name tokenisation
    TTIOCompressionRefDiff = 9,      // v1.2 M93: reference-based sequence diff
    TTIOCompressionReserved10 = 10,   // removed — no legacy .tio files exist
    TTIOCompressionDeltaRansOrder0 = 11,  // v1.2 M95: delta + rANS for integer channels
    TTIOCompressionFqzcompNx16Z = 12      // v1.2 M94.Z: CRAM-mimic rANS-Nx16 quality codec
};

typedef NS_ENUM(NSUInteger, TTIOByteOrder) {
    TTIOByteOrderLittleEndian = 0,
    TTIOByteOrderBigEndian
};

typedef NS_ENUM(NSInteger, TTIOPolarity) {
    TTIOPolarityUnknown  =  0,
    TTIOPolarityPositive =  1,
    TTIOPolarityNegative = -1
};

typedef NS_ENUM(NSUInteger, TTIOChromatogramType) {
    TTIOChromatogramTypeTIC = 0,
    TTIOChromatogramTypeXIC,
    TTIOChromatogramTypeSRM
};

typedef NS_ENUM(NSUInteger, TTIOAcquisitionMode) {
    TTIOAcquisitionModeMS1DDA = 0,
    TTIOAcquisitionModeMS2DDA,
    TTIOAcquisitionModeDIA,
    TTIOAcquisitionModeSRM,
    TTIOAcquisitionMode1DNMR,
    TTIOAcquisitionMode2DNMR,
    TTIOAcquisitionModeImaging,
    TTIOAcquisitionModeGenomicWGS,   // v0.11 M79: whole-genome sequencing
    TTIOAcquisitionModeGenomicWES    // v0.11 M79: whole-exome sequencing
};

typedef NS_ENUM(NSUInteger, TTIOEncryptionLevel) {
    TTIOEncryptionLevelNone = 0,
    TTIOEncryptionLevelDatasetGroup,
    TTIOEncryptionLevelDataset,
    TTIOEncryptionLevelDescriptorStream,
    TTIOEncryptionLevelAccessUnit
};

/**
 * Mid-IR measurement mode. `absorbance = -log10(transmittance)`; the
 * two are convertible so the exporter/importer preserves whichever
 * the source specified.
 */
typedef NS_ENUM(NSUInteger, TTIOIRMode) {
    TTIOIRModeTransmittance = 0,
    TTIOIRModeAbsorbance
};

/**
 * MS/MS precursor activation (dissociation) method.
 *
 * Stored as int32 in the optional `activation_methods` column of
 * `spectrum_index` (gated by feature flag `opt_ms2_activation_detail`).
 * `None` is the sentinel for MS1 scans and for MS2+ scans whose
 * activation method was not reported by the source instrument.
 *
 * Cross-language equivalents:
 *   Python: ttio.enums.ActivationMethod
 *   Java:   global.thalion.ttio.Enums.ActivationMethod
 */
typedef NS_ENUM(NSInteger, TTIOActivationMethod) {
    TTIOActivationMethodNone  = 0,
    TTIOActivationMethodCID   = 1,
    TTIOActivationMethodHCD   = 2,
    TTIOActivationMethodETD   = 3,
    TTIOActivationMethodUVPD  = 4,
    TTIOActivationMethodECD   = 5,
    TTIOActivationMethodEThcD = 6
};

#endif /* TTIO_ENUMS_H */
