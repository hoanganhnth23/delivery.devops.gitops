import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.net.http.WebSocketHandshakeException;
import java.time.Duration;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CompletionException;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Runtime-only raw WebSocket probe for the one-publisher Tracking contract. */
public final class TrackingPublisherProbe {
    private static final Pattern GENERATION =
            Pattern.compile("\\\"publisherGeneration\\\"\\s*:\\s*(\\d+)");

    private TrackingPublisherProbe() {}

    public static void main(String[] args) throws Exception {
        if (args.length == 7 && "participant".equals(args[1])) {
            verifyParticipantAuthorization(
                    URI.create(args[0]), args[2], args[3], args[4], args[5], args[6]);
            return;
        }
        if (args.length < 2 || (args.length != 2 && args.length != 3 && args.length != 5)) {
            throw new IllegalArgumentException(
                    "Usage: TrackingPublisherProbe <ws-url> <access-token> "
                            + "[hold-for-crash | cross-instance <direct-ws-url> <shipper-id>] "
                            + "OR <ws-url> participant <customer-token> <outsider-token> "
                            + "<shipper-token> <delivery-id> <shipper-id>");
        }
        URI uri = URI.create(args[0]);
        String token = args[1];

        if (args.length == 5) {
            if (!"cross-instance".equals(args[2])) {
                throw new IllegalArgumentException("Unknown probe mode: " + args[2]);
            }
            verifyCrossInstanceFence(uri, token, URI.create(args[3]), args[4]);
            return;
        }

        if (args.length == 3) {
            if (!"hold-for-crash".equals(args[2])) {
                throw new IllegalArgumentException("Unknown probe mode: " + args[2]);
            }
            holdPublisherForCrash(uri, token);
            return;
        }

        Client oldPublisher = connect(uri, token);
        long generation1 = generation(oldPublisher.await("connection_established", 10));
        oldPublisher.send("{\"action\":\"ping\"}");
        oldPublisher.await("\"type\":\"pong\"", 5);

        Client newPublisher = connect(uri, token);
        long generation2 = generation(newPublisher.await("connection_established", 10));
        require(generation2 > generation1, "new connection did not advance generation");
        oldPublisher.await("PUBLISHER_SUPERSEDED", 5);
        require(oldPublisher.awaitClose(5) == 1008, "old publisher was not policy-closed");

        newPublisher.send("{\"action\":\"update_location\",\"latitude\":10.7781,"
                + "\"longitude\":106.7021,\"accuracy\":4.0,\"isOnline\":true}");
        newPublisher.send("{\"action\":\"ping\"}");
        newPublisher.await("\"type\":\"pong\"", 5);
        newPublisher.close();
        newPublisher.awaitClose(5);

        Thread.sleep(Duration.ofSeconds(5).toMillis());
        Client reconnected = connect(uri, token);
        long generation3 = generation(reconnected.await("connection_established", 10));
        require(generation3 > generation2, "reconnect did not advance generation");

        for (int elapsed = 0; elapsed < 35; elapsed += 5) {
            reconnected.send("{\"action\":\"ping\"}");
            reconnected.await("\"type\":\"pong\"", 5);
            Thread.sleep(Duration.ofSeconds(5).toMillis());
        }
        reconnected.close();
        reconnected.awaitClose(5);

        System.out.printf(
                "Tracking publisher probe passed: generations=%d,%d,%d; supersede=1008; reconnect-held=35s%n",
                generation1, generation2, generation3);
    }

    private static void verifyParticipantAuthorization(
            URI uri, String customerToken, String outsiderToken, String shipperToken,
            String deliveryIdValue, String shipperIdValue) throws Exception {
        long deliveryId = positiveLong(deliveryIdValue, "delivery-id");
        long shipperId = positiveLong(shipperIdValue, "shipper-id");
        requireUnauthenticatedHandshakeRejected(uri);

        String subscription = "{\"action\":\"subscribe_shipper\",\"deliveryId\":"
                + deliveryId + ",\"shipperId\":" + shipperId + "}";
        Client outsider = connect(uri, outsiderToken);
        outsider.await("connection_established", 10);
        outsider.send(subscription);
        outsider.await("\"code\":\"FORBIDDEN\"", 10);

        Client customer = connect(uri, customerToken);
        customer.await("connection_established", 10);
        customer.send(subscription);
        String confirmation = customer.await("subscription_confirmed", 10);
        require(containsIdentity(confirmation, "shipperId", shipperId),
                "subscription confirmation has the wrong shipper identity");

        Client shipper = connect(uri, shipperToken);
        shipper.await("connection_established", 10);
        shipper.send("{\"action\":\"update_location\",\"shipperId\":999999999,"
                + "\"latitude\":10.7755,\"longitude\":106.7035,\"isOnline\":true}");
        // Subscription intentionally replays the last Redis location first. Wait
        // for the newly published coordinate rather than mistaking that replay
        // for the live propagation under test.
        String location = customer.await("\"latitude\":10.7755", 15);
        require(location.contains("\"type\":\"location_update\""),
                "expected coordinate was not delivered as a location update");
        require(containsIdentity(location, "shipperId", shipperId),
                "location update did not derive shipper identity from JWT");
        require(!containsIdentity(location, "shipperId", 999999999L),
                "location update trusted spoofed payload identity");
        require(location.contains("\"latitude\":10.7755"),
                "location update did not propagate the expected coordinates");

        shipper.close();
        customer.close();
        outsider.close();
        System.out.printf(
                "Tracking participant probe passed: unauthenticated=401, outsider=FORBIDDEN, "
                        + "participant subscribed, JWT shipperId=%d%n",
                shipperId);
    }

    private static void requireUnauthenticatedHandshakeRejected(URI uri) {
        try {
            HttpClient.newHttpClient().newWebSocketBuilder()
                    .connectTimeout(Duration.ofSeconds(10))
                    .buildAsync(uri, new Client())
                    .join();
            throw new IllegalStateException(
                    "Unauthenticated WebSocket handshake unexpectedly succeeded");
        } catch (CompletionException expected) {
            Throwable cause = expected.getCause();
            if (!(cause instanceof WebSocketHandshakeException handshake)
                    || handshake.getResponse().statusCode() != 401) {
                throw expected;
            }
        }
    }

    private static boolean containsIdentity(String message, String field, long value) {
        return message.contains("\"" + field + "\":" + value)
                || message.contains("\"" + field + "\":\"" + value + "\"");
    }

    private static long positiveLong(String raw, String name) {
        long value = Long.parseLong(raw);
        require(value > 0, name + " must be positive");
        return value;
    }

    private static void holdPublisherForCrash(URI uri, String token) throws Exception {
        Client publisher = connect(uri, token);
        long generation = generation(publisher.await("connection_established", 10));
        publisher.send("{\"action\":\"update_location\",\"latitude\":10.7782,"
                + "\"longitude\":106.7022,\"accuracy\":4.0,\"isOnline\":true}");
        publisher.send("{\"action\":\"ping\"}");
        publisher.await("\"type\":\"pong\"", 5);
        System.out.printf("Tracking crash publisher ready: generation=%d%n", generation);
        System.out.flush();
        int closeCode = publisher.awaitClose(600);
        System.out.printf("Tracking crash publisher disconnected: close=%d%n", closeCode);
    }

    private static void verifyCrossInstanceFence(
            URI gatewayUri, String token, URI directPeerUri, String shipperId) throws Exception {
        Client firstInstance = connect(gatewayUri, token);
        long generation1 = generation(firstInstance.await("connection_established", 10));

        Client secondInstance = connectDirect(directPeerUri, token);
        long generation2 = generation(secondInstance.await("connection_established", 10));
        require(generation2 > generation1, "peer instance did not advance generation");

        firstInstance.send("{\"action\":\"ping\"}");
        firstInstance.await("PUBLISHER_SUPERSEDED", 5);
        require(firstInstance.awaitClose(5) == 1008,
                "old publisher on first instance was not policy-closed");

        secondInstance.send("{\"action\":\"update_location\",\"latitude\":10.7783,"
                + "\"longitude\":106.7023,\"accuracy\":4.0,\"isOnline\":true}");
        secondInstance.send("{\"action\":\"ping\"}");
        secondInstance.await("\"type\":\"pong\"", 5);
        secondInstance.close();
        secondInstance.awaitClose(5);
        System.out.printf(
                "Tracking cross-instance fence passed: generations=%d,%d; old-close=1008%n",
                generation1, generation2);
    }

    private static Client connect(URI uri, String token) {
        Client listener = new Client();
        WebSocket socket = HttpClient.newHttpClient()
                .newWebSocketBuilder()
                .header("Authorization", "Bearer " + token)
                .connectTimeout(Duration.ofSeconds(10))
                .buildAsync(uri, listener)
                .join();
        listener.attach(socket);
        return listener;
    }

    private static Client connectDirect(URI uri, String token) {
        return connect(uri, token);
    }

    private static long generation(String message) {
        Matcher matcher = GENERATION.matcher(message);
        if (!matcher.find()) {
            throw new IllegalStateException("welcome message has no publisher generation");
        }
        return Long.parseLong(matcher.group(1));
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalStateException(message);
        }
    }

    private static final class Client implements WebSocket.Listener {
        private final BlockingQueue<String> messages = new LinkedBlockingQueue<>();
        private final CompletableFuture<Integer> closeCode = new CompletableFuture<>();
        private final StringBuilder partial = new StringBuilder();
        private WebSocket socket;

        void attach(WebSocket socket) {
            this.socket = socket;
        }

        void send(String text) {
            socket.sendText(text, true).join();
        }

        String await(String fragment, int seconds) throws Exception {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds);
            while (System.nanoTime() < deadline) {
                String message = messages.poll(200, TimeUnit.MILLISECONDS);
                if (message != null && message.contains(fragment)) {
                    return message;
                }
                if (closeCode.isDone()) {
                    throw new IllegalStateException(
                            "socket closed before message containing " + fragment);
                }
            }
            throw new IllegalStateException("timed out waiting for message containing " + fragment);
        }

        int awaitClose(int seconds) throws Exception {
            return closeCode.get(seconds, TimeUnit.SECONDS);
        }

        void close() {
            socket.sendClose(WebSocket.NORMAL_CLOSURE, "probe complete").join();
        }

        @Override
        public void onOpen(WebSocket webSocket) {
            webSocket.request(1);
        }

        @Override
        public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
            partial.append(data);
            if (last) {
                messages.add(partial.toString());
                partial.setLength(0);
            }
            webSocket.request(1);
            return null;
        }

        @Override
        public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
            closeCode.complete(statusCode);
            return null;
        }

        @Override
        public void onError(WebSocket webSocket, Throwable error) {
            closeCode.completeExceptionally(error);
        }
    }
}
