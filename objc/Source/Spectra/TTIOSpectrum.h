#ifndef TTIO_SPECTRUM_H
#define TTIO_SPECTRUM_H

#import <Foundation/Foundation.h>

#import "Providers/TTIOStorageProtocols.h"

@class TTIOSignalArray;
@class TTIOAxisDescriptor;

/**
 * <heading>TTIOSpectrum</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Spectra/TTIOSpectrum.h</p>
 *
 * <p>Base class for any spectrum. Holds an ordered dictionary of
 * named <code>TTIOSignalArray</code>s plus the coordinate axes
 * that index them, the spectrum's position in its parent run, scan
 * time, and optional precursor info for tandem MS.</p>
 *
 * <p>Concrete subclasses (<code>TTIOMassSpectrum</code>,
 * <code>TTIONMRSpectrum</code>, ...) add their own typed metadata
 * and validation.</p>
 *
 * <p><strong>Storage representation.</strong> Each spectrum is a
 * group whose immediate children are <code>TTIOSignalArray</code>
 * sub-groups (one per named array) plus scalar attributes for the
 * metadata fields. The provider-agnostic
 * <code>TTIOStorageGroup</code> protocol resolves the actual
 * backend (HDF5, Memory, SQLite, Zarr).</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.spectrum.Spectrum</code><br/>
 * Java: <code>global.thalion.ttio.Spectrum</code></p>
 */
@interface TTIOSpectrum : NSObject

/** Named signal arrays (e.g. <code>@"mz"</code> /
 *  <code>@"intensity"</code>). */
@property (readonly, copy) NSDictionary<NSString *, TTIOSignalArray *> *signalArrays;

/** Coordinate axes describing the signal arrays. */
@property (readonly, copy) NSArray<TTIOAxisDescriptor *> *axes;

/** Position in the parent <code>TTIOAcquisitionRun</code> (0-based);
 *  <code>0</code> if standalone. */
@property (readonly) NSUInteger indexPosition;

/** Scan time in seconds from run start; <code>0</code> if not
 *  applicable. */
@property (readonly) double scanTimeSeconds;

/** Precursor m/z for tandem MS; <code>0</code> if not tandem. */
@property (readonly) double precursorMz;

/** Precursor charge state; <code>0</code> if unknown. */
@property (readonly) NSUInteger precursorCharge;

/**
 * Designated initialiser.
 *
 * @param arrays           Named signal arrays.
 * @param axes             Coordinate axes.
 * @param indexPosition    Position in parent run.
 * @param scanTime         Scan time in seconds.
 * @param precursorMz      Precursor m/z (0 if not tandem).
 * @param precursorCharge  Precursor charge (0 if unknown).
 * @return An initialised spectrum.
 */
- (instancetype)initWithSignalArrays:(NSDictionary<NSString *, TTIOSignalArray *> *)arrays
                                axes:(NSArray<TTIOAxisDescriptor *> *)axes
                       indexPosition:(NSUInteger)indexPosition
                     scanTimeSeconds:(double)scanTime
                         precursorMz:(double)precursorMz
                     precursorCharge:(NSUInteger)precursorCharge;

#pragma mark - Storage round-trip

/**
 * Writes this spectrum into a new sub-group named <code>name</code>
 * under <code>parent</code>. Subclasses override
 * <code>-writeAdditionalAttributesToGroup:error:</code> to add their
 * typed metadata after the base class has written the common fields.
 *
 * @param parent Destination parent group.
 * @param name   Sub-group name.
 * @param error  Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent
                name:(NSString *)name
               error:(NSError **)error;

/**
 * Reads a spectrum sub-group. The receiving class chooses what to
 * read; subclasses override
 * <code>-readAdditionalAttributesFromGroup:error:</code> to pull
 * their typed metadata.
 *
 * @param parent Source parent group.
 * @param name   Sub-group name.
 * @param error  Out-parameter populated on failure.
 * @return The materialised spectrum, or <code>nil</code> on failure.
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Subclass hooks

/**
 * Override hook for subclass-specific attribute writing. Default is
 * a no-op.
 */
- (BOOL)writeAdditionalAttributesToGroup:(id<TTIOStorageGroup>)group
                                   error:(NSError **)error;

/**
 * Override hook for subclass-specific attribute reading. Default is
 * a no-op.
 */
- (BOOL)readAdditionalAttributesFromGroup:(id<TTIOStorageGroup>)group
                                    error:(NSError **)error;

@end

#endif
