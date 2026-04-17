# Objective-C API docs — placeholder

This directory is the intended output location for `autogsdoc`-generated
HTML reference documentation for libMPGO. It is empty in v0.6.1 because
the `autogsdoc` tool on Ubuntu's from-source libs-base build hits a
known `characterAtIndex:` crash when parsing `.h` inputs.

See `objc/Documentation/GNUmakefile` for the tool configuration.

## Regenerate locally

```
cd objc/Documentation
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make
cp -r html/. ../../docs/api/objc/
```

On a host where `autogsdoc` works (typically a clean libs-base checkout
on CI), the generated HTML populates this directory alongside
`../python/` and `../java/`.

## Cross-language reference

The class-by-class three-language parity map is in
`docs/api-review-v0.6.md`. The ObjC headers themselves under
`objc/Source/` carry full GSDoc-style class and method comments that
the other two languages mirror — so for ObjC developers the header
files are the canonical reference until the HTML build works.
