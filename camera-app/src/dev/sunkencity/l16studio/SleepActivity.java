package dev.sunkencity.l16studio;

import android.app.Activity;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Toast;

/**
 * Turns the screen off, as the power button would.
 *
 * It exists for cameras whose power button no longer works: it shows up in
 * the app list as "Screen off", and the gallery has a button that does the
 * same. It has no screen of its own; it acts and closes. It starts with a
 * short {@link NapActivity} (tap to wake), then really sleeps, after which
 * {@link WakeService} (lift to wake) is the way back.
 *
 * The first time, Android asks the user to allow the app to lock the screen.
 * Starting it with the extra "deactivate" set to true gives that permission
 * back, which Android requires before the app can be uninstalled.
 */
public class SleepActivity extends Activity {
    static final String EXTRA_DEACTIVATE = "deactivate";

    /** True when the app is allowed to turn the screen off. */
    static boolean isAllowed(Context context) {
        DevicePolicyManager policy = (DevicePolicyManager) context.getSystemService(Context.DEVICE_POLICY_SERVICE);
        return policy != null && policy.isAdminActive(new ComponentName(context, AdminReceiver.class));
    }

    /**
     * What the Screen off controls do: a short nap in which a tap wakes the
     * camera, then real sleep. Asks for permission first if needed.
     */
    static void sleep(Context context) {
        sleep(context, NapActivity.DEFAULT_SECONDS);
    }

    static void sleep(Context context, int napSeconds) {
        if (!isAllowed(context)) {
            askPermission(context);
            return;
        }
        Intent nap = new Intent(context, NapActivity.class);
        nap.putExtra(NapActivity.EXTRA_SECONDS, napSeconds);
        if (!(context instanceof Activity)) nap.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(nap);
    }

    /** Really turns the screen off now (the end of the nap). */
    static void sleepNow(Context context) {
        DevicePolicyManager policy = (DevicePolicyManager) context.getSystemService(Context.DEVICE_POLICY_SERVICE);
        if (policy == null || !isAllowed(context)) return;
        // Never put the camera to sleep without a way to wake it.
        WakeService.start(context);
        policy.lockNow();
    }

    private static void askPermission(Context context) {
        ComponentName admin = new ComponentName(context, AdminReceiver.class);
        Intent ask = new Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN);
        ask.putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin);
        ask.putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "L16 Studio needs this to turn the screen off for you. It is the only thing it will use it for.");
        if (!(context instanceof Activity)) ask.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(ask);
        Toast.makeText(context, "Allow this once, then use Screen off again.", Toast.LENGTH_LONG).show();
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (getIntent().getBooleanExtra(EXTRA_DEACTIVATE, false)) {
            DevicePolicyManager policy = (DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
            ComponentName admin = new ComponentName(this, AdminReceiver.class);
            if (policy != null && policy.isAdminActive(admin)) policy.removeActiveAdmin(admin);
            WakeService.stop(this);
        } else {
            sleep(this, getIntent().getIntExtra(NapActivity.EXTRA_SECONDS, NapActivity.DEFAULT_SECONDS));
        }
        finish();
    }
}
