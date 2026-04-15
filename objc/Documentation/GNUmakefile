include $(GNUSTEP_MAKEFILES)/common.make

# ---------------------------------------------------------------------------
# autogsdoc — generate GSDoc-style HTML API documentation for libMPGO.
# ---------------------------------------------------------------------------
# Builds into objc/Documentation/html/ by default. Run from objc/ via
# `make docs` (added to the top-level GNUmakefile) or directly here:
#
#     . /usr/share/GNUstep/Makefiles/GNUstep.sh
#     make
#
# The resulting HTML uses the same look as the GNUstep base/gui reference
# documentation, with cross-references between MPGO classes and Foundation
# types, an alphabetical class index, and per-method anchors.
#
# NOTE: requires a working `autogsdoc` from gnustep-base. Some source
# builds of libs-base ship an autogsdoc whose NSFileManager
# fileExistsAtPath: returns NO for files that exist (the symptom is
# `Tried to add nil to array` or `characterAtIndex: index out of range`
# with no output). If you hit this, rebuild libs-base from a clean
# checkout, or run the docs target on CI where the from-source libs-base
# build is generally healthy.

DOCUMENT_NAME = libMPGO

libMPGO_HEADER_FILES_DIR = ../Source

libMPGO_AGSDOC_FILES = \
	../Source/Protocols/MPGOIndexable.h \
	../Source/Protocols/MPGOStreamable.h \
	../Source/Protocols/MPGOCVAnnotatable.h \
	../Source/Protocols/MPGOProvenanceable.h \
	../Source/Protocols/MPGOEncryptable.h \
	../Source/ValueClasses/MPGOEnums.h \
	../Source/ValueClasses/MPGOValueRange.h \
	../Source/ValueClasses/MPGOEncodingSpec.h \
	../Source/ValueClasses/MPGOAxisDescriptor.h \
	../Source/ValueClasses/MPGOCVParam.h \
	../Source/HDF5/MPGOHDF5Errors.h \
	../Source/HDF5/MPGOHDF5Types.h \
	../Source/HDF5/MPGOHDF5File.h \
	../Source/HDF5/MPGOHDF5Group.h \
	../Source/HDF5/MPGOHDF5Dataset.h \
	../Source/HDF5/MPGOHDF5Attribute.h \
	../Source/Core/MPGOSignalArray.h \
	../Source/Spectra/MPGOSpectrum.h \
	../Source/Spectra/MPGOMassSpectrum.h \
	../Source/Spectra/MPGONMRSpectrum.h \
	../Source/Spectra/MPGONMR2DSpectrum.h \
	../Source/Spectra/MPGOFreeInductionDecay.h \
	../Source/Spectra/MPGOChromatogram.h \
	../Source/Run/MPGOInstrumentConfig.h \
	../Source/Run/MPGOSpectrumIndex.h \
	../Source/Run/MPGOAcquisitionRun.h \
	../Source/Dataset/MPGOIdentification.h \
	../Source/Dataset/MPGOQuantification.h \
	../Source/Dataset/MPGOProvenanceRecord.h \
	../Source/Dataset/MPGOTransitionList.h \
	../Source/Dataset/MPGOSpectralDataset.h \
	../Source/Image/MPGOMSImage.h \
	../Source/Protection/MPGOAccessPolicy.h \
	../Source/Protection/MPGOEncryptionManager.h \
	../Source/Query/MPGOQuery.h \
	../Source/Query/MPGOStreamWriter.h \
	../Source/Query/MPGOStreamReader.h

libMPGO_AGSDOC_FLAGS = \
	-MakeFrames YES \
	-DocumentationDirectory html \
	-Project libMPGO

include $(GNUSTEP_MAKEFILES)/documentation.make
