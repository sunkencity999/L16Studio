package dev.sunkencity.l16studio;

import android.app.admin.DeviceAdminReceiver;

/**
 * Lets the app turn the screen off (see {@link SleepActivity}). Android only
 * allows that for a "device administrator", so the app registers as one with
 * a single permission, force-lock, and nothing else.
 */
public class AdminReceiver extends DeviceAdminReceiver {
}
