include $(GNUSTEP_MAKEFILES)/common.make

LIBRARY_NAME = libMPGO

libMPGO_HEADER_FILES_DIR = .
libMPGO_HEADER_FILES_INSTALL_DIR = /MPGO

libMPGO_HEADER_FILES = \
	Protocols/MPGOIndexable.h \
	Protocols/MPGOStreamable.h \
	Protocols/MPGOCVAnnotatable.h \
	Protocols/MPGOProvenanceable.h \
	Protocols/MPGOEncryptable.h \
	ValueClasses/MPGOCVParam.h \
	ValueClasses/MPGOAxisDescriptor.h \
	ValueClasses/MPGOEncodingSpec.h \
	ValueClasses/MPGOValueRange.h \
	ValueClasses/MPGOEnums.h \
	HDF5/MPGOHDF5Errors.h \
	HDF5/MPGOHDF5Types.h \
	HDF5/MPGOHDF5File.h \
	HDF5/MPGOHDF5Group.h \
	HDF5/MPGOHDF5Dataset.h \
	HDF5/MPGOHDF5Attribute.h \
	Core/MPGOSignalArray.h \
	Spectra/MPGOSpectrum.h \
	Spectra/MPGOMassSpectrum.h \
	Spectra/MPGONMRSpectrum.h \
	Spectra/MPGONMR2DSpectrum.h \
	Spectra/MPGOFreeInductionDecay.h \
	Spectra/MPGOChromatogram.h \
	Run/MPGOInstrumentConfig.h \
	Run/MPGOSpectrumIndex.h \
	Run/MPGOAcquisitionRun.h \
	Dataset/MPGOIdentification.h \
	Dataset/MPGOQuantification.h \
	Dataset/MPGOProvenanceRecord.h \
	Dataset/MPGOTransitionList.h \
	Dataset/MPGOSpectralDataset.h \
	Image/MPGOMSImage.h \
	Protection/MPGOAccessPolicy.h \
	Protection/MPGOEncryptionManager.h \
	Query/MPGOQuery.h \
	Query/MPGOStreamWriter.h \
	Query/MPGOStreamReader.h

libMPGO_OBJC_FILES = \
	ValueClasses/MPGOCVParam.m \
	ValueClasses/MPGOAxisDescriptor.m \
	ValueClasses/MPGOEncodingSpec.m \
	ValueClasses/MPGOValueRange.m \
	HDF5/MPGOHDF5Errors.m \
	HDF5/MPGOHDF5Types.m \
	HDF5/MPGOHDF5File.m \
	HDF5/MPGOHDF5Group.m \
	HDF5/MPGOHDF5Dataset.m \
	Core/MPGOSignalArray.m \
	Spectra/MPGOSpectrum.m \
	Spectra/MPGOMassSpectrum.m \
	Spectra/MPGONMRSpectrum.m \
	Spectra/MPGONMR2DSpectrum.m \
	Spectra/MPGOFreeInductionDecay.m \
	Spectra/MPGOChromatogram.m \
	Run/MPGOInstrumentConfig.m \
	Run/MPGOSpectrumIndex.m \
	Run/MPGOAcquisitionRun.m \
	Dataset/MPGOIdentification.m \
	Dataset/MPGOQuantification.m \
	Dataset/MPGOProvenanceRecord.m \
	Dataset/MPGOTransitionList.m \
	Dataset/MPGOSpectralDataset.m \
	Image/MPGOMSImage.m \
	Protection/MPGOAccessPolicy.m \
	Protection/MPGOEncryptionManager.m \
	Query/MPGOQuery.m \
	Query/MPGOStreamWriter.m \
	Query/MPGOStreamReader.m

libMPGO_LIBRARIES_DEPEND_UPON += -lhdf5 -lz -lcrypto

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble
