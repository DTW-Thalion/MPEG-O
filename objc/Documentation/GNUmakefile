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

# NB: -MakeFrames MUST be NO. With MakeFrames=YES, autogsdoc emits bare
# <body> pages (no wrapper divs) plus a <FRAMESET> index.html. The
# shipped default-styles.css sets `body { display: flex; height: 100vh; }`
# expecting .content-bar / .content-pane children — without those
# wrappers the direct body children flow left-to-right and the page is
# unreadable. -MakeFrames NO puts the CSS-navigation wrappers back in
# every class page and produces a proper HTML5 layout (no frameset).
libMPGO_AGSDOC_FLAGS = \
	-MakeFrames NO \
	-DocumentationDirectory html \
	-Project libMPGO

include $(GNUSTEP_MAKEFILES)/documentation.make

# Install the hand-written landing page after autogsdoc runs. With
# -MakeFrames NO autogsdoc doesn't emit an index.html of its own; every
# class page carries the sidebar, but we still want a single-URL entry
# point for the doc site.
after-all::
	@cp index.html.in libMPGO/index.html
	@echo " Installed landing page: libMPGO/index.html"
