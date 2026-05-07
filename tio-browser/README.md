# tio-browser

JavaFX desktop application for inspecting, importing, exporting, and
transporting TTI-O `.tio` multi-omics datasets. Built on `global.thalion:ttio`.

This README is a skeleton — Phase 14 fleshes out prerequisites,
build commands, native-binary install hints, and the Diagnostics dialog
documentation.

## Quick build

    mvn -pl tio-browser package -Dhdf5.jar=/usr/share/java/jarhdf5.jar
    java -jar tio-browser/target/tio-browser-0.1.0-shaded.jar

## License

LGPL-3.0-or-later. See LICENSE.
