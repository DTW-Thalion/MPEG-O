package global.thalion.ttio.browser;

/**
 * Hard failure during {@link Hdf5NativeLoader#ensureLoaded()}. Thrown
 * when the bundled HDF5 native libs cannot be extracted, the platform
 * isn't supported, or System.load fails on a core lib.
 *
 * <p>{@link App#start} catches this, shows a modal Alert, and exits.
 */
public class Hdf5NativeLoadException extends RuntimeException {
    public Hdf5NativeLoadException(String message) { super(message); }
    public Hdf5NativeLoadException(String message, Throwable cause) {
        super(message, cause);
    }
}
