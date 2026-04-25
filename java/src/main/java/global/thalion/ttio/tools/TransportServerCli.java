/*
 * TTI-O Java Implementation — v0.10 M68.5.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.transport.TransportServer;

/**
 * Command-line transport server. Parallel to Python
 * {@code python -m ttio.tools.transport_server_cli} and ObjC
 * {@code TtioTransportServer}.
 *
 * <p>Usage:
 * <pre>
 *   java -cp target/classes:/usr/share/java/jarhdf5.jar:&lt;other-deps&gt; \
 *        -Djava.library.path=/usr/lib/x86_64-linux-gnu/jni \
 *        global.thalion.ttio.tools.TransportServerCli \
 *        input.tio [--host 127.0.0.1] [--port 0]
 * </pre>
 *
 * <p>Required on the classpath: {@code jarhdf5} (provided by the
 * system HDF5 Java bindings, e.g. {@code /usr/share/java/jarhdf5.jar}
 * on Debian/Ubuntu), {@code Java-WebSocket}, {@code slf4j-api},
 * {@code slf4j-simple}, {@code sqlite-jdbc}, {@code bcprov-jdk18on}.
 * When running via Maven ({@code mvn exec:java}), these resolve
 * automatically from the pom.</p>
 *
 * <p>Prints {@code PORT=<n>} to stdout once bound so supervisors can
 * discover the actual port (matches the Python CLI).</p>
 */
public final class TransportServerCli {

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: TransportServerCli <path.tio> "
                    + "[--host 127.0.0.1] [--port 0]");
            System.exit(2);
        }
        String path = args[0];
        String host = "127.0.0.1";
        int port = 0;
        for (int i = 1; i + 1 < args.length; i += 2) {
            if ("--host".equals(args[i])) host = args[i + 1];
            else if ("--port".equals(args[i])) port = Integer.parseInt(args[i + 1]);
        }
        TransportServer server = new TransportServer(path, host, port);
        server.start();
        System.out.println("PORT=" + server.port());
        System.out.flush();
        // Block until parent sends SIGTERM.
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try { server.stop(); } catch (Exception ignored) {}
        }));
        Thread.currentThread().join();
    }
}
