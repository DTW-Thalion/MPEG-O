/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.workspaces;

import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.scene.Scene;
import javafx.stage.Stage;
import org.junit.jupiter.api.Test;
import org.testfx.framework.junit5.ApplicationTest;

import static org.junit.jupiter.api.Assertions.*;

class JobsWorkspaceTest extends ApplicationTest {

    private JobsWorkspace ws;

    @Override
    public void start(Stage stage) {
        ConnectionManager.instance().disconnect();
        ws = new JobsWorkspace(stage);
        stage.setScene(new Scene(ws.node(), 1000, 700));
        stage.show();
    }

    @Test
    void hasJobsAndSessionsContentAndButtons() {
        assertNotNull(ws.jobsContentForTest());
        assertNotNull(ws.sessionsContentForTest());
        assertNotNull(ws.newJobButtonForTest());
        assertNotNull(ws.newSessionButtonForTest());
        assertEquals("New job…", ws.newJobButtonForTest().getText());
        assertEquals("New session…", ws.newSessionButtonForTest().getText());
    }
}
