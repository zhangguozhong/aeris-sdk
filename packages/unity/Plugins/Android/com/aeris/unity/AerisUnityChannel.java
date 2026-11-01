package com.aeris.unity;

import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executor;

/** UnityLibrary 唯一拥有的通用通道；不依赖 Unity SDK、Android API 或宿主业务 SDK。 */
public final class AerisUnityChannel {
    public interface Callback { void onMessage(String payload); void onClosed(String reason); }
    public interface Emitter { void emit(String payload); void disconnect(String reason); }
    public interface Receiver { void receive(String payload); void close(); }
    public interface ReceiverFactory { Receiver create(Emitter emitter); }
    private static final Object LOCK = new Object();
    private static final Map<String, Binding> BINDINGS = new HashMap<>();
    private static final Map<Long, Endpoint> ENDPOINTS = new HashMap<>();
    private static final int MAX_CHANNELS = 128, MAX_MESSAGES = 128;
    private static final long MAX_BYTES = 4L * 1024 * 1024;
    private static final int MAX_PAYLOAD = 2 * 1024 * 1024;
    private static long nextHandle;
    private static boolean unloading;
    private static int activeCallbacks, activeManagedCalls;
    private AerisUnityChannel() {}

    public static final class Binding implements AutoCloseable {
        private final String channel;
        private ReceiverFactory factory;
        private final Executor dispatcher;
        private Endpoint endpoint;
        private boolean closed;
        private Binding(String channel, ReceiverFactory factory, Executor dispatcher) {
            this.channel = channel; this.factory = factory; this.dispatcher = dispatcher;
        }
        @Override public void close() {
            synchronized (LOCK) {
                if (closed) return;
                closed = true; factory = null;
                if (BINDINGS.get(channel) == this) BINDINGS.remove(channel);
                if (endpoint != null) endpoint.finish("HOST_CLOSED", true);
            }
        }
    }

    public static Binding bind(String channel, ReceiverFactory factory, Executor dispatcher) {
        synchronized (LOCK) {
            validateChannel(channel);
            if (factory == null || dispatcher == null) throw new IllegalArgumentException("Expected factory and dispatcher");
            if (unloading || BINDINGS.containsKey(channel)) throw new IllegalStateException("Channel unavailable or already bound");
            if (BINDINGS.size() >= MAX_CHANNELS) throw new IllegalStateException("Channel budget exceeded");
            Binding binding = new Binding(channel, factory, dispatcher);
            BINDINGS.put(channel, binding);
            return binding;
        }
    }

    public static long open(String channel, Callback callback) {
        synchronized (LOCK) {
            activeManagedCalls++;
            try {
            validateChannel(channel);
            Binding binding = BINDINGS.get(channel);
            if (unloading || binding == null || binding.closed || binding.endpoint != null)
                throw new IllegalStateException("Channel unavailable or already open");
            if (callback == null) throw new IllegalArgumentException("Expected callback");
            if (nextHandle == Long.MAX_VALUE) throw new IllegalStateException("Handles exhausted");
            Endpoint endpoint = new Endpoint(++nextHandle, binding, callback);
            binding.endpoint = endpoint; ENDPOINTS.put(endpoint.handle, endpoint);
            endpoint.tasks.add(new Task(null, 0, false));
            endpoint.schedule();
            if (endpoint.closed) throw new IllegalStateException("Cannot create receiver");
            return endpoint.handle;
            } finally { activeManagedCalls--; }
        }
    }

    public static void send(long handle, String payload) {
        synchronized (LOCK) {
            activeManagedCalls++;
            try {
            Endpoint endpoint = ENDPOINTS.get(handle);
            if (endpoint == null) throw new IllegalStateException("Stale or closed handle");
            endpoint.enqueue(payload, false);
            } finally { activeManagedCalls--; }
        }
    }
    public static void close(long handle) {
        synchronized (LOCK) {
            activeManagedCalls++;
            try {
            Endpoint endpoint = ENDPOINTS.get(handle);
            if (endpoint != null) endpoint.finish("CLIENT_CLOSED", false);
            } finally { activeManagedCalls--; }
        }
    }
    /** 必须在销毁 Unity 运行时之前调用；返回后没有托管回调或保留的代理。 */
    public static void prepareUnload() {
        synchronized (LOCK) {
            if (activeCallbacks != 0 || activeManagedCalls != 0) throw new IllegalStateException("Leave callback stack before unloading");
            unloading = true;
            for (Endpoint endpoint : new ArrayList<>(ENDPOINTS.values())) endpoint.finish("UNLOADING", false);
            for (Binding binding : new ArrayList<>(BINDINGS.values())) binding.close();
        }
    }
    public static void resume() {
        synchronized (LOCK) {
            if (!ENDPOINTS.isEmpty() || !BINDINGS.isEmpty()) throw new IllegalStateException("Channels still bound");
            unloading = false;
        }
    }
    private static void validateChannel(String value) {
        if (value == null || !value.matches("[a-zA-Z0-9_.:-]{1,128}")) throw new IllegalArgumentException("Invalid channel");
    }
    private static int bytes(String value) {
        if (value == null || value.length() == 0 || value.length() > MAX_PAYLOAD) throw new IllegalArgumentException("Invalid payload");
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value));
            if (encoded.remaining() > MAX_PAYLOAD) throw new IllegalArgumentException("Payload too large");
            return encoded.remaining();
        } catch (CharacterCodingException error) { throw new IllegalArgumentException("Invalid UTF-8", error); }
    }
    private static final class Task {
        final String text; final int bytes; final boolean emit;
        Task(String text, int bytes, boolean emit) { this.text = text; this.bytes = bytes; this.emit = emit; }
    }
    private static final class Endpoint implements Emitter {
        final long handle;
        final Binding binding;
        final ArrayDeque<Task> tasks = new ArrayDeque<>();
        Callback callback;
        Receiver receiver;
        long queuedBytes;
        int queuedMessages;
        boolean scheduled, closed;
        Endpoint(long handle, Binding binding, Callback callback) {
            this.handle = handle; this.binding = binding; this.callback = callback;
        }
        void enqueue(String payload, boolean emit) {
            if (closed) return;
            int size;
            try { size = bytes(payload); }
            catch (RuntimeException error) { finish("INVALID_PAYLOAD", true); throw error; }
            if (queuedMessages >= MAX_MESSAGES || size > MAX_BYTES - queuedBytes) {
                finish("QUEUE_EXCEEDED", true); throw new IllegalStateException("Queue budget exceeded");
            }
            tasks.add(new Task(payload, size, emit)); queuedBytes += size; queuedMessages++; schedule();
        }
        void schedule() {
            if (scheduled || closed) return;
            scheduled = true;
            try { binding.dispatcher.execute(this::drain); }
            catch (RuntimeException error) { finish("DISPATCH_FAILED", true); throw error; }
        }
        void drain() {
            synchronized (LOCK) {
                try {
                    while (!closed && !tasks.isEmpty()) {
                        Task task = tasks.remove(); queuedBytes -= task.bytes;
                        if (task.text == null) {
                            Receiver created = binding.factory.create(this);
                            // Factory 可同步取消绑定；新建 Receiver 仍须在宿主线程释放。
                            if (closed) { if (created != null) created.close(); return; }
                            if (created == null) throw new IllegalStateException("Receiver unavailable");
                            receiver = created;
                        } else {
                            queuedMessages--;
                            if (task.emit) {
                                activeCallbacks++;
                                try { callback.onMessage(task.text); } finally { activeCallbacks--; }
                            } else receiver.receive(task.text);
                        }
                    }
                } catch (Exception error) { finish("RECEIVER_FAILED", true); }
                finally { scheduled = false; }
            }
        }
        @Override public void emit(String payload) {
            synchronized (LOCK) {
                if (closed) return;
                try { enqueue(payload, true); } catch (RuntimeException ignored) { /* 不能把异常送回业务异步回调。 */ }
            }
        }
        @Override public void disconnect(String reason) {
            synchronized (LOCK) {
                String code = reason != null && reason.matches("[A-Z0-9_]{1,64}") ? reason : "HOST_DISCONNECTED";
                finish(code, true);
            }
        }
        void finish(String reason, boolean notify) {
            if (closed) return;
            closed = true; tasks.clear(); queuedBytes = 0; queuedMessages = 0;
            ENDPOINTS.remove(handle);
            if (binding.endpoint == this) binding.endpoint = null;
            Callback previous = callback; callback = null;
            Receiver previousReceiver = receiver; receiver = null;
            if (previousReceiver != null) {
                try { binding.dispatcher.execute(() -> { try { previousReceiver.close(); } catch (Exception ignored) {} }); }
                catch (RuntimeException ignored) { /* Dispatcher 生命周期必须覆盖 Binding。 */ }
            }
            if (notify && previous != null) {
                activeCallbacks++;
                try { previous.onClosed(reason); } catch (Exception ignored) {}
                finally { activeCallbacks--; }
            }
        }
    }
}
