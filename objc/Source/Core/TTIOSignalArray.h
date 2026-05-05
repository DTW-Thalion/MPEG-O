#ifndef TTIO_SIGNAL_ARRAY_H
#define TTIO_SIGNAL_ARRAY_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOCVAnnotatable.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOAxisDescriptor.h"
#import "ValueClasses/TTIOCVParam.h"
#import "Providers/TTIOStorageProtocols.h"

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOCVAnnotatable</p>
 * <p><em>Declared In:</em> Core/TTIOSignalArray.h</p>
 *
 * <p>The atomic unit of measured signal in TTI-O. A SignalArray
 * wraps a typed numeric buffer with an encoding spec, an optional
 * axis descriptor, and an arbitrary number of controlled-vocabulary
 * annotations. It is the primitive every TTI-O spectrum and run is
 * built from.</p>
 *
 * <p>Construction is via
 * <code>-initWithBuffer:length:encoding:axis:</code> with raw bytes;
 * the caller is responsible for matching the buffer layout to the
 * encoding's <code>elementSize</code>. Provider-agnostic round-trip
 * is via <code>-writeToGroup:name:chunkSize:compressionLevel:error:</code>
 * and <code>+readFromGroup:name:error:</code>; the storage provider
 * (HDF5, Memory, SQLite, Zarr) is resolved at the
 * <code>TTIOStorageGroup</code> protocol layer.</p>
 *
 * <p>Not thread-safe. Mutating CV annotations from multiple threads
 * is undefined behaviour; callers requiring concurrency must wrap
 * the array externally.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.signal_array.SignalArray</code><br/>
 * Java: <code>global.thalion.ttio.SignalArray</code></p>
 */
@interface TTIOSignalArray : NSObject <TTIOCVAnnotatable>

/** Raw byte buffer holding the signal data. Length in bytes equals
 *  <code>length * encoding.elementSize</code>. */
@property (readonly, copy) NSData *buffer;

/** Element count (not byte count). */
@property (readonly) NSUInteger length;

/** Wire-format encoding (precision + compression + byte order). */
@property (readonly, strong) TTIOEncodingSpec *encoding;

/** Optional axis descriptor; <code>nil</code> when the axis is
 *  unknown (e.g. raw byte buffers without semantic interpretation). */
@property (readonly, strong) TTIOAxisDescriptor *axis;

/**
 * Designated initialiser. Creates a SignalArray from a raw byte
 * buffer.
 *
 * @param buffer   Raw bytes; must contain exactly
 *                 <code>length * encoding.elementSize</code> bytes.
 * @param length   Number of signal elements (not bytes).
 * @param encoding Wire-format encoding.
 * @param axis     Optional axis descriptor; pass <code>nil</code>
 *                 if unknown.
 * @return An initialised SignalArray, or <code>nil</code> on
 *         failure.
 */
- (instancetype)initWithBuffer:(NSData *)buffer
                        length:(NSUInteger)length
                      encoding:(TTIOEncodingSpec *)encoding
                          axis:(TTIOAxisDescriptor *)axis;

#pragma mark - Storage round-trip (provider-agnostic)

/**
 * Writes the signal buffer + encoding + axis + CV annotations to a
 * storage group through the <code>TTIOStorageGroup</code> protocol.
 * Provider-agnostic — the same call succeeds against HDF5, Memory,
 * SQLite, and Zarr providers with byte-equal canonical output.
 *
 * @param group            Destination group.
 * @param name             Dataset name within <code>group</code>.
 * @param chunkSize        Chunk size in elements (HDF5/Zarr); pass
 *                         <code>0</code> for contiguous storage.
 * @param compressionLevel zlib level for HDF5 (<code>0</code>-<code>9</code>).
 * @param error            Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)group
                name:(NSString *)name
           chunkSize:(NSUInteger)chunkSize
    compressionLevel:(int)compressionLevel
               error:(NSError **)error;

/**
 * Reads a signal array previously written by
 * <code>-writeToGroup:name:chunkSize:compressionLevel:error:</code>.
 *
 * @param group Source group.
 * @param name  Dataset name within <code>group</code>.
 * @param error Out-parameter populated on failure.
 * @return The materialised SignalArray, or <code>nil</code> on
 *         failure.
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)group
                         name:(NSString *)name
                        error:(NSError **)error;

#pragma mark - Equality

/**
 * Value equality on (buffer, length, encoding, axis, CV annotations).
 * Two SignalArrays compare equal iff every component is equal.
 *
 * @param other Object to compare against.
 * @return <code>YES</code> if value-equal.
 */
- (BOOL)isEqual:(id)other;

/** @return Hash consistent with <code>-isEqual:</code>. */
- (NSUInteger)hash;

@end

#endif
