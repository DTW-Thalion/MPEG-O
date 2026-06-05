/*
 * TTIOSpectralDataset+Internal.h
 * TTI-O Objective-C Implementation
 *
 * Internal SPI shared between TTIOSpectralDataset.m (core) and its
 * category implementation files (e.g. TTIOSpectralDataset+GenomicWrite.m).
 * NOT a public header — never installed; only #imported by the
 * TTIOSpectralDataset .m translation units.
 *
 * Declares the handful of file-internal helpers that are defined in the
 * core .m but called from the genomic-write category (and vice versa),
 * plus the little-endian serialisation macros both files rely on.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIOSpectralDataset_Internal_h
#define TTIOSpectralDataset_Internal_h

#import "TTIOSpectralDataset.h"
#import "Providers/TTIOStorageProtocols.h"

// little-endian serialisation helpers. Use macOS's
// libkern/OSByteOrder.h when available; fall back to endian.h on
// Linux (GNUstep on x86/ARM). The serialisation is non-negotiable
// LE per Binding Decision §118; on big-endian platforms a per-element
// byte swap is required so the wire bytes are identical across hosts.
#if defined(__APPLE__)
#  include <libkern/OSByteOrder.h>
#  define TTIO_HOST_TO_LE32(x) OSSwapHostToLittleInt32(x)
#  define TTIO_HOST_TO_LE64(x) OSSwapHostToLittleInt64(x)
#else
#  include <endian.h>
#  define TTIO_HOST_TO_LE32(x) htole32(x)
#  define TTIO_HOST_TO_LE64(x) htole64(x)
#endif

// v1.0 single format-version stamp. Defined once in TTIOSpectralDataset.m;
// shared with the +GenomicWrite category which also stamps this version.
extern NSString *const kTTIOFormatVersion;

// Bridge to the dynamically-resolved TTIOHDF5GroupAdapter. Defined in the
// core .m; called from both the read path (core) and the genomic-write
// category.
id _TTIO_MakeHDF5GroupAdapter(id group);

// URL-scheme routing helper. Defined in the core .m; called from the core
// write/read paths and from the genomic-write category's +writeMinimalToPath:.
BOOL isNonHdf5ProviderURL(NSString *url);

#endif /* TTIOSpectralDataset_Internal_h */
