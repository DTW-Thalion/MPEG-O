package global.thalion.ttio.browser;

import javafx.scene.Scene;
import javafx.scene.layout.BorderPane;
import javafx.stage.Stage;

public class MainWindow {

    private Stage stage;
    private BorderPane root;

    public void show(Stage primaryStage) {
        this.stage = primaryStage;
        this.root = new BorderPane();
        Scene scene = new Scene(root, 1280, 800);
        primaryStage.setScene(scene);
        primaryStage.setTitle("tio-browser");
        primaryStage.show();
    }

    public void dispose() {
        if (stage != null) stage.close();
    }

    // Exposed for tests
    BorderPane root() { return root; }
}
