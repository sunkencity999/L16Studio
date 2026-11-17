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
 *  - the tilt detector, which fires when the camera is picked up or turned
 *    (its orientation changes by about 35 degrees);
 *  - the proximity sensor, so that uncovering the camera (taking it out of a
 *    bag, lifting a hand off it) also wakes it, and so that a tilt while the
 *    sensor is covered is ignored: a camera jostling inside a bag stays asleep.
 *
 * Nothing is listened to while the screen is on. The service runs whenever
 * the app's Screen off control is in use, because turning the screen off on a
 * camera with no working power button is only safe if it can be woken again.
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

    private SensorManager sensors;
    private Sensor tilt, proximity;
    private PowerManager power;
    private boolean armed;
    private boolean covered;
    private long screenOffAt;

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
        if (tilt != null) sensors.registerListener(this, tilt, SensorManager.SENSOR_DELAY_NORMAL);
        if (proximity != null) sensors.registerListener(this, proximity, SensorManager.SENSOR_DELAY_NORMAL);
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
            if (uncovered && settled) wake();
        } else if (event.sensor.getType() == TYPE_TILT_DETECTOR) {
            if (!covered && settled) wake();
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {}

    @SuppressWarnings("deprecation")
    private void wake() {
        // A screen wake lock with ACQUIRE_CAUSES_WAKEUP is the way an ordinary
        // app turns the display on; it is released again after a moment and
        // the normal screen timeout takes over.
        PowerManager.WakeLock lock = power.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP | PowerManager.ON_AFTER_RELEASE,
                "l16studio:lift-to-wake");
        lock.acquire(3000);
    }

    /** Restarts lift-to-wake after the camera boots, if Screen off is in use. */
    public static class BootReceiver extends BroadcastReceiver {
        @Override public void onReceive(Context context, Intent intent) {
            if (SleepActivity.isAllowed(context)) start(context);
        }
    }
}
