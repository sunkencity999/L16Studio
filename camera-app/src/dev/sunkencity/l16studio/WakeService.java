package dev.sunkencity.l16studio;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;

/**
 * Wakes the camera without the power button.
 *
 * While the screen is off this listens to two sensors that Android can
 * deliver even when the device is asleep ("wake-up" sensors):
 *
 *  - the accelerometer, read in small batches, which catches an ordinary
 *    pick-up: a turn of about 12 degrees from how the camera was lying, or
 *    being moved;
 *  - the tilt detector (a 35-degree change), as a low-power backstop;
 *  - the proximity sensor, so that uncovering the camera (taking it out of a
 *    bag, lifting a hand off it) also wakes it, and so that a tilt while the
 *    sensor is covered is ignored: a camera jostling inside a bag stays asleep.
 *
 * Nothing is listened to while the screen is on. The service runs all the
 * time once the user has allowed the app's screen controls, because the
 * screen also turns off by itself (the timeout), and a camera with no
 * working power button must always have a way to be woken.
 */
public class WakeService extends Service implements SensorEventListener {
    /**
     * The tilt detector's sensor type. Android defines it (22) and the camera
     * provides it, but the constant isn't part of the public SDK at this
     * API level, so it is spelled out here.
     */
    private static final int TYPE_TILT_DETECTOR = 22;

    /** Ignore sensor activity this soon after the screen goes off (it is still being put down). */
    private static final long SETTLE_MS = 1500;

    // Pick-up detection from the accelerometer. The tilt detector alone needs
    // a 35-degree change held for two seconds, which felt like having to
    // shake the camera awake; these catch an ordinary pick-up.
    /** Wake when the camera has turned this far from how it was lying. */
    private static final float TURN_DEGREES = 12f;
    /** Wake on a movement this strong (m/s^2 away from gravity alone)... */
    private static final float JOLT = 1.3f;
    /** ...seen in this many readings in a row, so a single knock is ignored. */
    private static final int JOLT_READINGS = 2;
    /** Accelerometer readings are taken this often... */
    private static final int SAMPLE_US = 100_000;
    /** ...and delivered in batches this far apart, so the processor can doze in between. */
    private static final int BATCH_US = 600_000;

    private SensorManager sensors;
    private Sensor tilt, proximity, accelerometer;
    private PowerManager power;
    private boolean armed;
    private boolean covered;
    private long screenOffAt;
    /** Gravity as the camera lay when it settled; null until then. */
    private float[] rest;
    private final float[] smooth = new float[3];
    private boolean haveSmooth;
    private int jolts;

    private final BroadcastReceiver screenState = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) arm(); else disarm();
        }
    };

    static void start(Context context) {
        context.startService(new Intent(context, WakeService.class));
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, WakeService.class));
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        power = (PowerManager) getSystemService(POWER_SERVICE);
        sensors = (SensorManager) getSystemService(SENSOR_SERVICE);
        // The second argument asks for the wake-up variant of each sensor.
        tilt = sensors.getDefaultSensor(TYPE_TILT_DETECTOR, true);
        proximity = sensors.getDefaultSensor(Sensor.TYPE_PROXIMITY, true);
        accelerometer = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER, true);

        IntentFilter filter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_SCREEN_ON);
        registerReceiver(screenState, filter);

        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, GalleryActivity.class), 0);
        Notification notification = new Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_lock_idle_low_battery)
                .setContentTitle("Lift to wake is on")
                .setContentText("Pick the camera up, or uncover it, to turn the screen on.")
                .setPriority(Notification.PRIORITY_MIN)
                .setContentIntent(open)
                .setOngoing(true)
                .build();
        startForeground(2, notification);

        if (!power.isInteractive()) arm();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        disarm();
        unregisterReceiver(screenState);
        super.onDestroy();
    }

    private void arm() {
        if (armed) return;
        armed = true;
        covered = false;
        screenOffAt = SystemClock.elapsedRealtime();
        rest = null;
        haveSmooth = false;
        jolts = 0;
        if (tilt != null) sensors.registerListener(this, tilt, SensorManager.SENSOR_DELAY_NORMAL);
        if (proximity != null) sensors.registerListener(this, proximity, SensorManager.SENSOR_DELAY_NORMAL);
        if (accelerometer != null) sensors.registerListener(this, accelerometer, SAMPLE_US, BATCH_US);
    }

    private void disarm() {
        if (!armed) return;
        armed = false;
        sensors.unregisterListener(this);
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        if (!armed) return;
        boolean settled = SystemClock.elapsedRealtime() - screenOffAt > SETTLE_MS;
        if (event.sensor.getType() == Sensor.TYPE_PROXIMITY) {
            boolean near = event.values[0] < Math.min(event.sensor.getMaximumRange(), 5f);
            boolean uncovered = covered && !near;
            covered = near;
            if (uncovered && settled) wake("uncovered");
        } else if (event.sensor.getType() == TYPE_TILT_DETECTOR) {
            if (!covered && settled) wake("tilt detector");
        } else if (event.sensor.getType() == Sensor.TYPE_ACCELEROMETER) {
            onAcceleration(event.values, settled);
        }
    }

    /**
     * Wakes on a pick-up: either the camera has turned from how it was lying,
     * or it is being moved. While the proximity sensor is covered (in a bag,
     * face down) nothing wakes it, and the resting position follows along.
     */
    private void onAcceleration(float[] a, boolean settled) {
        // A slow average follows gravity; the difference from it is movement.
        if (!haveSmooth) {
            System.arraycopy(a, 0, smooth, 0, 3);
            haveSmooth = true;
        } else {
            for (int i = 0; i < 3; i++) smooth[i] += 0.25f * (a[i] - smooth[i]);
        }
        if (!settled) return;
        if (rest == null || covered) {
            rest = smooth.clone();
            jolts = 0;
            return;
        }

        float magnitude = (float) Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
        jolts = Math.abs(magnitude - SensorManager.GRAVITY_EARTH) > JOLT ? jolts + 1 : 0;

        float dot = smooth[0] * rest[0] + smooth[1] * rest[1] + smooth[2] * rest[2];
        float lengths = (float) (Math.sqrt(smooth[0] * smooth[0] + smooth[1] * smooth[1] + smooth[2] * smooth[2])
                * Math.sqrt(rest[0] * rest[0] + rest[1] * rest[1] + rest[2] * rest[2]));
        float turned = lengths > 0 ? (float) Math.toDegrees(Math.acos(Math.max(-1, Math.min(1, dot / lengths)))) : 0;

        if (turned > TURN_DEGREES) {
            wake(String.format("turned %.0f degrees", turned));
        } else if (jolts >= JOLT_READINGS) {
            wake("moved");
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {}

    @SuppressWarnings("deprecation")
    private void wake(String reason) {
        // Recorded so a wake (or a false one) can be traced afterwards with logcat.
        android.util.Log.i("L16Wake", "waking: " + reason);
        // A screen wake lock with ACQUIRE_CAUSES_WAKEUP is the way an ordinary
        // app turns the display on; it is released again after a moment and
        // the normal screen timeout takes over.
        PowerManager.WakeLock lock = power.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP | PowerManager.ON_AFTER_RELEASE,
                "l16studio:lift-to-wake");
        lock.acquire(3000);
    }

    /** Starts the service if the user has enabled the screen controls. */
    static void startIfAllowed(Context context) {
        if (SleepActivity.isAllowed(context)) start(context);
    }

    /**
     * Brings lift-to-wake back after the camera boots and after the app is
     * updated (an update stops the app's services). The screen can go off by
     * its own timeout at any moment, not only through Screen off, so the
     * service has to be running all the time, not just after Screen off.
     */
    public static class BootReceiver extends BroadcastReceiver {
        @Override public void onReceive(Context context, Intent intent) {
            startIfAllowed(context);
        }
    }
}
