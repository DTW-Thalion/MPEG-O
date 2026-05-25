package global.thalion.ttio.browser;

import javafx.scene.input.KeyCombination;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;
import static org.junit.jupiter.api.Assertions.*;

class MainWindowKeyboardShortcutsTest extends ApplicationTest {

    private MainWindow win;

    @Override public void start(Stage stage) { win = new MainWindow(); win.show(stage); }

    @Test
    void openItemHasShortcutAccelerator() {
        assertNotNull(win.openMenuItem().getAccelerator());
        assertEquals(KeyCombination.keyCombination("Shortcut+O"),
            win.openMenuItem().getAccelerator());
    }

    @Test
    void closeItemHasShortcutAccelerator() {
        assertNotNull(win.closeMenuItem().getAccelerator());
        assertEquals(KeyCombination.keyCombination("Shortcut+W"),
            win.closeMenuItem().getAccelerator());
    }

    @Test
    void exitItemHasShortcutAccelerator() {
        assertNotNull(win.exitMenuItem().getAccelerator());
        assertEquals(KeyCombination.keyCombination("Shortcut+Q"),
            win.exitMenuItem().getAccelerator());
    }
}
