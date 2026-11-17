package dev.sunkencity.l16studio;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Serves the camera's shots over Wi-Fi so they can be pulled without a cable.
 *
 * A small HTTP server on port 8016, advertised on the local network as
 * "_l16studio._tcp" so L16Studio on the Mac can find it:
 *
 *   GET /               a plain web page of the shots, for any browser
 *   GET /api/shots      JSON list: name, raw size, preview size, modified time
 *   GET /raw/NAME.lri   the raw file (supports Range, so downloads can resume)
 *   GET /preview/NAME.jpg   the in-camera preview
 *   GET /thumb/NAME.jpg     a small version of the preview
 *
 * It is read-only, has no authentication, and runs only while the user has
 * switched it on, so it is meant for a trusted network.
 */
public class TransferService extends Service {
    static final int PORT = 8016;
    static final String ACTION_STATE = "dev.sunkencity.l16studio.TRANSFER_STATE";
    private static final String SERVICE_TYPE = "_l16studio._tcp.";

    private static volatile boolean running;

    static boolean isRunning() { return running; }

    /** The camera's Wi-Fi address, or null when it isn't connected. */
    static String localAddress(Context context) {
        WifiManager wifi = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi == null || wifi.getConnectionInfo() == null) return null;
        int ip = wifi.getConnectionInfo().getIpAddress();
        if (ip == 0) return null;
        return String.format(Locale.US, "%d.%d.%d.%d", ip & 0xff, (ip >> 8) & 0xff, (ip >> 16) & 0xff, (ip >> 24) & 0xff);
    }

    private ServerSocket server;
    private ExecutorService workers;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private NsdManager.RegistrationListener registration;

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (running) return START_STICKY;
        try {
            server = new ServerSocket(PORT);
        } catch (IOException e) {
            stopSelf();
            return START_NOT_STICKY;
        }
        running = true;
        workers = Executors.newFixedThreadPool(4);

        // Keep the CPU and Wi-Fi radio awake while transfers may be running.
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "l16studio:transfer");
        wakeLock.acquire();
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
        wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "l16studio:transfer");
        wifiLock.acquire();

        String address = localAddress(this);
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, GalleryActivity.class), 0);
        Notification notification = new Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("L16 Studio Wi-Fi transfer is on")
                .setContentText(address == null ? "Waiting for Wi-Fi" : "http://" + address + ":" + PORT)
                .setContentIntent(open)
                .setOngoing(true)
                .build();
        startForeground(1, notification);

        advertise();
        new Thread(new Runnable() {
            @Override public void run() { acceptLoop(); }
        }, "l16-transfer-accept").start();
        sendBroadcast(new Intent(ACTION_STATE));
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        try { if (server != null) server.close(); } catch (IOException ignored) {}
        if (workers != null) workers.shutdownNow();
        if (registration != null) {
            try {
                ((NsdManager) getSystemService(NSD_SERVICE)).unregisterService(registration);
            } catch (IllegalArgumentException ignored) {}
        }
        if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        sendBroadcast(new Intent(ACTION_STATE));
        super.onDestroy();
    }

    private void advertise() {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("Light L16");
        info.setServiceType(SERVICE_TYPE);
        info.setPort(PORT);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onRegistrationFailed(NsdServiceInfo i, int code) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo i, int code) {}
            @Override public void onServiceRegistered(NsdServiceInfo i) {}
            @Override public void onServiceUnregistered(NsdServiceInfo i) {}
        };
        try {
            ((NsdManager) getSystemService(NSD_SERVICE)).registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
        } catch (RuntimeException e) {
            registration = null; // discovery is a convenience; the address still works
        }
    }

    private void acceptLoop() {
        while (running) {
            try {
                final Socket socket = server.accept();
                workers.execute(new Runnable() {
                    @Override public void run() {
                        try {
                            handle(socket);
                        } catch (IOException ignored) {
                            // client went away mid-transfer
                        } finally {
                            try { socket.close(); } catch (IOException ignored) {}
                        }
                    }
                });
            } catch (IOException e) {
                break; // socket closed on shutdown
            }
        }
    }

    // ---- HTTP -----------------------------------------------------------

    private void handle(Socket socket) throws IOException {
        socket.setSoTimeout(30000);
        InputStream in = socket.getInputStream();
        OutputStream out = new BufferedOutputStream(socket.getOutputStream(), 64 * 1024);

        // Read the request head (up to the blank line).
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        int last4 = 0, b;
        while (head.size() < 16384 && (b = in.read()) != -1) {
            head.write(b);
            last4 = (last4 << 8) | b;
            if (last4 == 0x0D0A0D0A) break; // "\r\n\r\n"
        }
        String[] lines = head.toString("ISO-8859-1").split("\r\n");
        String[] request = lines.length > 0 ? lines[0].split(" ") : new String[0];
        if (request.length < 2 || !(request[0].equals("GET") || request[0].equals("HEAD"))) {
            respond(out, 405, "text/plain", "Only GET is supported.".getBytes(StandardCharsets.UTF_8), false);
            out.flush();
            return;
        }
        boolean headOnly = request[0].equals("HEAD");
        String range = null;
        for (String line : lines) {
            if (line.toLowerCase(Locale.US).startsWith("range:")) range = line.substring(6).trim();
        }
        String path = request[1];
        int query = path.indexOf('?');
        if (query >= 0) path = path.substring(0, query);

        if (path.equals("/")) {
            respond(out, 200, "text/html; charset=utf-8", page().getBytes(StandardCharsets.UTF_8), headOnly);
        } else if (path.equals("/api/shots")) {
            respond(out, 200, "application/json", json().getBytes(StandardCharsets.UTF_8), headOnly);
        } else if (path.startsWith("/raw/") || path.startsWith("/preview/") || path.startsWith("/thumb/")) {
            String file = path.substring(path.lastIndexOf('/') + 1);
            int dot = file.lastIndexOf('.');
            // Shot names are plain "L16_00001"-style tokens; reject anything else
            // so a request can never reach outside the camera folder.
            String name = dot > 0 ? file.substring(0, dot) : file;
            Shots.Shot shot = name.matches("[A-Za-z0-9_\\-]+") ? Shots.find(name) : null;
            if (shot == null) {
                respond(out, 404, "text/plain", "No such shot.".getBytes(StandardCharsets.UTF_8), headOnly);
            } else if (path.startsWith("/raw/")) {
                sendFile(out, shot.raw, "application/octet-stream", range, headOnly);
            } else if (path.startsWith("/preview/")) {
                sendFile(out, shot.preview, "image/jpeg", range, headOnly);
            } else {
                Bitmap thumb = Shots.loadThumb(shot, 400);
                if (thumb == null) {
                    respond(out, 404, "text/plain", "No preview yet.".getBytes(StandardCharsets.UTF_8), headOnly);
                } else {
                    ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
                    thumb.compress(Bitmap.CompressFormat.JPEG, 80, jpeg);
                    respond(out, 200, "image/jpeg", jpeg.toByteArray(), headOnly);
                }
            }
        } else {
            respond(out, 404, "text/plain", "Not found.".getBytes(StandardCharsets.UTF_8), headOnly);
        }
        out.flush();
    }

    private static void respond(OutputStream out, int status, String type, byte[] body, boolean headOnly) throws IOException {
        String reason = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Error";
        String head = "HTTP/1.1 " + status + " " + reason + "\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + body.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.ISO_8859_1));
        if (!headOnly) out.write(body);
    }

    private static void sendFile(OutputStream out, File file, String type, String range, boolean headOnly) throws IOException {
        if (!file.exists()) {
            respond(out, 404, "text/plain", "That file isn't on the camera.".getBytes(StandardCharsets.UTF_8), headOnly);
            return;
        }
        long length = file.length(), start = 0, end = length - 1;
        boolean partial = false;
        if (range != null && range.startsWith("bytes=")) {
            String[] parts = range.substring(6).split("-", 2);
            try {
                if (!parts[0].isEmpty()) start = Long.parseLong(parts[0]);
                if (parts.length > 1 && !parts[1].isEmpty()) end = Math.min(end, Long.parseLong(parts[1]));
                partial = start <= end && start < length;
            } catch (NumberFormatException ignored) {
                partial = false;
            }
            if (!partial) { start = 0; end = length - 1; }
        }
        String head = "HTTP/1.1 " + (partial ? "206 Partial Content" : "200 OK") + "\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + (end - start + 1) + "\r\n"
                + "Accept-Ranges: bytes\r\n"
                + (partial ? "Content-Range: bytes " + start + "-" + end + "/" + length + "\r\n" : "")
                + "Content-Disposition: attachment; filename=\"" + file.getName() + "\"\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.ISO_8859_1));
        if (headOnly) return;
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            raf.seek(start);
            byte[] buffer = new byte[256 * 1024];
            long remaining = end - start + 1;
            while (remaining > 0) {
                int n = raf.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                if (n < 0) break;
                out.write(buffer, 0, n);
                remaining -= n;
            }
        }
    }

    private static String json() {
        List<Shots.Shot> shots = Shots.list();
        StringBuilder sb = new StringBuilder("{\"camera\":\"Light L16\",\"shots\":[");
        for (int i = 0; i < shots.size(); i++) {
            Shots.Shot s = shots.get(i);
            if (i > 0) sb.append(',');
            sb.append("{\"name\":\"").append(s.name).append("\"")
              .append(",\"rawSize\":").append(s.raw.exists() ? s.raw.length() : 0)
              .append(",\"previewSize\":").append(s.preview.exists() ? s.preview.length() : 0)
              .append(",\"modified\":").append(s.modified() / 1000)
              .append('}');
        }
        return sb.append("]}").toString();
    }

    private static String page() {
        List<Shots.Shot> shots = Shots.list();
        StringBuilder sb = new StringBuilder();
        sb.append("<!doctype html><html><head><meta charset=\"utf-8\">")
          .append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
          .append("<title>Light L16</title><style>")
          .append("body{background:#0e0e0f;color:#f2f2f2;font:15px -apple-system,Helvetica,Arial,sans-serif;margin:0;padding:16px}")
          .append("h1{font-size:20px;margin:0 0 4px}p{color:#9a9aa0;margin:0 0 16px}")
          .append(".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}")
          .append(".shot{background:#1b1b1d;border-radius:8px;overflow:hidden}")
          .append(".shot img{width:100%;aspect-ratio:4/3;object-fit:cover;display:block;background:#242428}")
          .append(".shot div{padding:8px 10px}.shot b{display:block;margin-bottom:4px}")
          .append("a{color:#ffb338;text-decoration:none;margin-right:12px}")
          .append("</style></head><body><h1>Light L16</h1><p>")
          .append(shots.size()).append(shots.size() == 1 ? " shot" : " shots")
          .append(" on the camera. Raw files open in L16Studio.</p><div class=\"grid\">");
        for (Shots.Shot s : shots) {
            sb.append("<div class=\"shot\"><img loading=\"lazy\" src=\"/thumb/").append(s.name).append(".jpg\" alt=\"\"><div><b>")
              .append(s.name).append("</b>");
            if (s.raw.exists()) {
                sb.append("<a href=\"/raw/").append(s.name).append(".lri\">Raw (")
                  .append(Shots.formatSize(s.raw.length())).append(")</a>");
            }
            if (s.preview.exists()) {
                sb.append("<a href=\"/preview/").append(s.name).append(".jpg\">Preview</a>");
            }
            sb.append("</div></div>");
        }
        return sb.append("</div></body></html>").toString();
    }
}
