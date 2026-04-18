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
	Core/MPGONumpress.h \
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
	Dataset/MPGOCompoundIO.h \
	Image/MPGOMSImage.h \
	Protection/MPGOAccessPolicy.h \
	Protection/MPGOAnonymizer.h \
	Protection/MPGOEncryptionManager.h \
	Protection/MPGOKeyRotationManager.h \
	Protection/MPGOSignatureManager.h \
	Protection/MPGOVerifier.h \
	Query/MPGOQuery.h \
	Query/MPGOStreamWriter.h \
	Query/MPGOStreamReader.h \
	Import/MPGOBase64.h \
	Import/MPGOCVTermMapper.h \
	Import/MPGOMzMLReader.h \
	Import/MPGONmrMLReader.h \
	Import/MPGOThermoRawReader.h \
	Export/MPGOMzMLWriter.h \
	Export/MPGONmrMLWriter.h \
	Export/MPGOISAExporter.h \
	Providers/MPGOCompoundField.h \
	Providers/MPGOStorageProtocols.h \
	Providers/MPGOProviderRegistry.h \
	Providers/MPGOCanonicalBytes.h \
	Providers/MPGOHDF5Provider.h \
	Providers/MPGOMemoryProvider.h \
	Providers/MPGOSqliteProvider.h

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
	HDF5/MPGOHDF5CompoundType.m \
	HDF5/MPGOFeatureFlags.m \
	Core/MPGOSignalArray.m \
	Core/MPGONumpress.m \
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
	Dataset/MPGOCompoundIO.m \
	Image/MPGOMSImage.m \
	Protection/MPGOAccessPolicy.m \
	Protection/MPGOAnonymizer.m \
	Protection/MPGOEncryptionManager.m \
	Protection/MPGOKeyRotationManager.m \
	Protection/MPGOSignatureManager.m \
	Protection/MPGOVerifier.m \
	Query/MPGOQuery.m \
	Query/MPGOStreamWriter.m \
	Query/MPGOStreamReader.m \
	Import/MPGOBase64.m \
	Import/MPGOCVTermMapper.m \
	Import/MPGOMzMLReader.m \
	Import/MPGONmrMLReader.m \
	Import/MPGOThermoRawReader.m \
	Export/MPGOMzMLWriter.m \
	Export/MPGONmrMLWriter.m \
	Export/MPGOISAExporter.m \
	Providers/MPGOCompoundField.m \
	Providers/MPGOProviderRegistry.m \
	Providers/MPGOCanonicalBytes.m \
	Providers/MPGOHDF5Provider.m \
	Providers/MPGOMemoryProvider.m \
	Providers/MPGOSqliteProvider.m

libMPGO_LIBRARIES_DEPEND_UPON += -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble
