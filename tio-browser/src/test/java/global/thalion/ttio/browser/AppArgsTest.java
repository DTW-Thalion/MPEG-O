package global.thalion.ttio.browser;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import java.util.Optional;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for {@link App#parseOpenPath(List)} CLI argument parsing.
 *
 * <p>Exercises the production code path without spinning up a JavaFX
 * runtime: {@code parseOpenPath} is a pure static helper that mirrors
 * what {@code App.start} consumes from {@code getParameters().getRaw()}.
 */
class AppArgsTest {

    @Test
    void openFlagReturnsPath() {
        assertEquals(Optional.of("/foo.tio"),
            App.parseOpenPath(List.of("--open", "/foo.tio")));
    }

    @Test
    void noFlagReturnsEmpty() {
        assertEquals(Optional.empty(), App.parseOpenPath(List.of()));
    }

    @Test
    void openFlagWithoutValueReturnsEmpty() {
        assertEquals(Optional.empty(), App.parseOpenPath(List.of("--open")));
    }

    @Test
    void unrelatedArgsReturnEmpty() {
        assertEquals(Optional.empty(),
            App.parseOpenPath(List.of("--verbose", "--debug")));
    }

    @Test
    void nullArgsReturnsEmpty() {
        assertEquals(Optional.empty(), App.parseOpenPath(null));
    }

    @Test
    void openFlagWithEmptyStringValueReturnsEmpty() {
        // Closes the dead-branch coverage gap on App.parseOpenPath's
        // !v.isEmpty() guard. Treats `--open ""` the same as `--open`
        // alone — silent skip rather than a crash or alert.
        assertEquals(Optional.empty(),
            App.parseOpenPath(List.of("--open", "")));
    }
}
