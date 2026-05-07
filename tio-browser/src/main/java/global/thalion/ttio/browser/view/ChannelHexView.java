package global.thalion.ttio.browser.view;

import global.thalion.ttio.SignalArray;
import global.thalion.ttio.Spectrum;
import javafx.scene.Node;
import javafx.scene.control.ListView;
import javafx.scene.control.SplitPane;
import javafx.scene.control.TextArea;
import javafx.scene.layout.HBox;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * Per-spectrum named-channel inspector. Left pane lists the spectrum's
 * named {@link SignalArray} channels; the right pane shows the first
 * 4 KiB of the selected channel as a hex dump.
 *
 * <p>Driven by header-table row selection, like {@link
 * global.thalion.ttio.browser.view.plot.SpectrumPlotView}.</p>
 */
public class ChannelHexView {

    private static final int HEX_DUMP_LIMIT_BYTES = 4096;

    private final ListView<String> channelList = new ListView<>();
    private final TextArea hexArea = new TextArea();
    private final SplitPane root = new SplitPane(channelList, new HBox(hexArea));
    private Spectrum currentSpectrum;

    public ChannelHexView() {
        channelList.setMinWidth(180);
        hexArea.setEditable(false);
        hexArea.setStyle("-fx-font-family: monospace; -fx-font-size: 10pt;");
        HBox.setHgrow(hexArea, javafx.scene.layout.Priority.ALWAYS);
        root.setDividerPositions(0.25);
        channelList.getSelectionModel().selectedItemProperty().addListener(
            (obs, old, sel) -> {
                if (sel != null && currentSpectrum != null) {
                    SignalArray ch = currentSpectrum.signalArray(sel);
                    hexArea.setText(formatHex(sel, ch));
                }
            });
    }

    public Node content() { return root; }
    public ListView<String> channelList() { return channelList; }
    public TextArea hexArea() { return hexArea; }

    public void render(Spectrum s) {
        this.currentSpectrum = s;
        if (s == null) {
            channelList.getItems().clear();
            hexArea.clear();
            return;
        }
        List<String> names = new ArrayList<>(s.signalArrays().keySet());
        java.util.Collections.sort(names);
        channelList.getItems().setAll(names);
        hexArea.clear();
        if (!names.isEmpty()) {
            channelList.getSelectionModel().select(0);
        }
    }

    public void clear() {
        currentSpectrum = null;
        channelList.getItems().clear();
        hexArea.clear();
    }

    private static String formatHex(String name, SignalArray a) {
        if (a == null) return "(channel " + name + " not found)";
        byte[] bytes = bytesOf(a);
        int show = Math.min(bytes.length, HEX_DUMP_LIMIT_BYTES);
        StringBuilder sb = new StringBuilder();
        sb.append("Channel: ").append(name).append('\n');
        sb.append("Precision: ").append(a.encoding().precision())
          .append(", elements: ").append(a.length())
          .append(", bytes: ").append(bytes.length).append('\n');
        sb.append('\n');
        for (int i = 0; i < show; i += 16) {
            sb.append(String.format("%08x  ", i));
            for (int j = 0; j < 16 && i + j < show; j++) {
                sb.append(String.format("%02x ", bytes[i + j] & 0xff));
            }
            sb.append('\n');
        }
        if (bytes.length > show) {
            sb.append("\n... ").append(bytes.length - show)
              .append(" more bytes (truncated for display)\n");
        }
        return sb.toString();
    }

    /**
     * Materialize a SignalArray's underlying buffer as a byte array.
     * The on-disk encoding is float64 for almost everything, but we
     * dispatch on whatever {@code asDoubles} / {@code asInts} / etc.
     * the array actually exposes for its current precision.
     */
    private static byte[] bytesOf(SignalArray a) {
        try {
            double[] d = a.asDoubles();
            if (d != null && d.length > 0) {
                ByteBuffer bb = ByteBuffer.allocate(d.length * Double.BYTES)
                                          .order(ByteOrder.LITTLE_ENDIAN);
                for (double v : d) bb.putDouble(v);
                return bb.array();
            }
        } catch (RuntimeException ignored) {
            // fall through to int handling below
        }
        try {
            int[] i = a.asInts();
            if (i != null && i.length > 0) {
                ByteBuffer bb = ByteBuffer.allocate(i.length * Integer.BYTES)
                                          .order(ByteOrder.LITTLE_ENDIAN);
                for (int v : i) bb.putInt(v);
                return bb.array();
            }
        } catch (RuntimeException ignored) {
            // fall through
        }
        return new byte[0];
    }
}
