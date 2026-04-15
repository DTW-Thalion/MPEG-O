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
	ValueClasses/MPGOEnums.h

libMPGO_OBJC_FILES = \
	ValueClasses/MPGOCVParam.m \
	ValueClasses/MPGOAxisDescriptor.m \
	ValueClasses/MPGOEncodingSpec.m \
	ValueClasses/MPGOValueRange.m

libMPGO_LIBRARIES_DEPEND_UPON += -lhdf5 -lz

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble
