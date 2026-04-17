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

# Use shell glob to pick up every public header (including post-M41 additions)
libMPGO_AGSDOC_FILES := $(shell find ../Source -name '*.h')

libMPGO_AGSDOC_FLAGS = \
	-MakeFrames YES \
	-DocumentationDirectory html \
	-Project libMPGO

include $(GNUSTEP_MAKEFILES)/documentation.make
