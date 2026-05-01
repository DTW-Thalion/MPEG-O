#ifndef TTIO_SPECTRUM_H
#define TTIO_SPECTRUM_H

#import <Foundation/Foundation.h>

#import "Providers/TTIOStorageProtocols.h"

@class TTIOSignalArray;
@class TTIOAxisDescriptor;

/**
 * Base class for any spectrum. Holds an ordered dictionary of named
 * TTIOSignalArrays plus the coordinate axes that index them, the
 * spectrum's position in its parent run, scan time, and optional
 * precursor info for tandem MS.
 *
 * Concrete subclasses (TTIOMassSpectrum, TTIONMRSpectrum, ...) add
 * their own typed metadata and validation.
 *
 * HDF5 representation: each spectrum is an HDF5 group whose immediate
 * children are TTIOSignalArray sub-groups (one per named array) plus
 * scalar attributes for the metadata fields.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.spectrum.Spectrum
 *   Java:   global.thalion.ttio.Spectrum
 */
@interface TTIOSpectrum : NSObject

/** Named SignalArrays — e.g. @"mz" / @"intensity". */
@property (readonly, copy) NSDictionary<NSString *, TTIOSignalArray *> *signalArrays;

/** Coordinate axes describing the SignalArrays. */
@property (readonly, copy) NSArray<TTIOAxisDescriptor *> *axes;

/** Position in the parent AcquisitionRun (0-based). 0 if standalone. */
@property (readonly) NSUInteger indexPosition;

/** Scan time in seconds from run start. 0 if not applicable. */
@property (readonly) double scanTimeSeconds;

/** Precursor m/z for tandem MS. 0 if not tandem. */
@property (readonly) double precursorMz;

/** Precursor charge state. 0 if unknown. */
@property (readonly) NSUInteger precursorCharge;

- (instancetype)initWithSignalArrays:(NSDictionary<NSString *, TTIOSignalArray *> *)arrays
                                axes:(NSArray<TTIOAxisDescriptor *> *)axes
                       indexPosition:(NSUInteger)indexPosition
                     scanTimeSeconds:(double)scanTime
                         precursorMz:(double)precursorMz
                     precursorCharge:(NSUInteger)precursorCharge;

#pragma mark - HDF5 round-trip

/**
 * Write this spectrum into a new sub-group named `name` under `parent`.
 * Subclasses override -writeAdditionalAttributesToGroup:error: to add
 * their typed metadata after the base class has written the common fields.
 */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent
                name:(NSString *)name
               error:(NSError **)error;

/**
 * Read a spectrum sub-group. The receiving class chooses what to read;
 * subclasses override -readAdditionalAttributesFromGroup:error: to pull
 * their typed metadata.
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Subclass hooks

/** Override to write subclass-specific attributes. Default is a no-op. */
- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group
                                   error:(NSError **)error;

/** Override to read subclass-specific attributes. Default is a no-op. */
- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group
                                    error:(NSError **)error;

@end

#endif
