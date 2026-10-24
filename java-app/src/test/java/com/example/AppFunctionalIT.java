package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

/**
 * Functional tests - start the real HTTP server and call it over the network.
 * Named *FunctionalIT so failsafe runs them in "mvn verify", not surefire.
 */
class AppFunctionalIT {

    private static HttpServer server;
    private static String base;
    private static final HttpClient client = HttpClient.newHttpClient();

    @BeforeAll
    static void startServer() throws IOException {
        server = App.start(0); // port 0 = any free port
        base = "http://localhost:" + server.getAddress().getPort();
    }

    @AfterAll
    static void stopServer() {
        server.stop(0);
    }

    private static HttpResponse<String> get(String path) throws Exception {
        return client.send(HttpRequest.newBuilder(URI.create(base + path)).build(),
                HttpResponse.BodyHandlers.ofString());
    }

    @Test
    void rootReturnsGreeting() throws Exception {
        HttpResponse<String> r = get("/");
        assertEquals(200, r.statusCode());
        assertEquals("Hello from demo-app", r.body());
    }

    @Test
    void healthReturnsOk() throws Exception {
        HttpResponse<String> r = get("/health");
        assertEquals(200, r.statusCode());
        assertEquals("OK", r.body());
    }

    @Test
    void addEndpointAddsNumbers() throws Exception {
        HttpResponse<String> r = get("/add?a=2&b=40");
        assertEquals(200, r.statusCode());
        assertEquals("42", r.body());
    }

    @Test
    void addEndpointRejectsBadInput() throws Exception {
        HttpResponse<String> r = get("/add?a=x&b=1");
        assertEquals(400, r.statusCode());
    }
}
