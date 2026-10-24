package com.example;

import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

/**
 * Tiny HTTP service using only the JDK (no frameworks), so the pipeline has
 * something real to build, test, scan, containerize and deploy.
 *
 *   GET /        -> "Hello from demo-app"
 *   GET /health  -> "OK"
 *   GET /add?a=1&b=2 -> "3"
 */
public class App {

    public static HttpServer start(int port) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

        server.createContext("/", exchange -> respond(exchange, 200, "Hello from demo-app"));
        server.createContext("/health", exchange -> respond(exchange, 200, "OK"));
        server.createContext("/add", exchange -> {
            try {
                String query = exchange.getRequestURI().getQuery();
                int a = param(query, "a");
                int b = param(query, "b");
                respond(exchange, 200, String.valueOf(Calculator.add(a, b)));
            } catch (IllegalArgumentException e) {
                respond(exchange, 400, "bad request: " + e.getMessage());
            }
        });

        server.start();
        return server;
    }

    static int param(String query, String name) {
        if (query == null) {
            throw new IllegalArgumentException("missing query string");
        }
        for (String pair : query.split("&")) {
            String[] kv = pair.split("=", 2);
            if (kv.length == 2 && kv[0].equals(name)) {
                try {
                    return Integer.parseInt(kv[1]);
                } catch (NumberFormatException e) {
                    throw new IllegalArgumentException(name + " must be an integer");
                }
            }
        }
        throw new IllegalArgumentException("missing parameter " + name);
    }

    private static void respond(com.sun.net.httpserver.HttpExchange exchange, int status, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "text/plain; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        start(port);
        System.out.println("demo-app listening on :" + port);
    }
}
