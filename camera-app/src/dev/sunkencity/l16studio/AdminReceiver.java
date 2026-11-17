package dev.sunkencity.l16studio;

import android.app.admin.DeviceAdminReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Lets the app turn the screen off (see {@link SleepActivity}). Android only
 * allows that for a "device administrator", so the app registers as one with
 * a single permission, force-lock, and nothing else.
 */
public class AdminReceiver extends DeviceAdminReceiver {
    @Override
    public void onEnabled(Context context, Intent intent) {
        // Allowed to turn the screen off: make sure it can be woken from now on.
        WakeService.start(context);
    }

    @Override
    public void onDisabled(Context context, Intent intent) {
        WakeService.stop(context);
    }
}
