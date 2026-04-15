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
	Core/MPGOSignalArray.h

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
	Core/MPGOSignalArray.m

libMPGO_LIBRARIES_DEPEND_UPON += -lhdf5 -lz

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble
