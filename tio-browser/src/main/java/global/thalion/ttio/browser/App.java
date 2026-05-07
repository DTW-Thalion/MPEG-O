package global.thalion.ttio.browser;

import javafx.application.Application;
import javafx.stage.Stage;

public class App extends Application {

    private MainWindow mainWindow;

    @Override
    public void start(Stage primaryStage) {
        mainWindow = new MainWindow();
        mainWindow.show(primaryStage);
    }

    @Override
    public void stop() {
        if (mainWindow != null) {
            mainWindow.dispose();
        }
    }

    public static void main(String[] args) {
        launch(args);
    }
}
