package dev.sunkencity.l16studio;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * The first stage of Screen off: a black screen at the lowest backlight that
 * any tap (or key) dismisses at once.
 *
 * The L16's touch panel is powered down when the screen is really off and
 * has no wake gesture, so a tap can only wake the camera while the display
 * is still technically on. This keeps it that way for a short while, looking
 * off, and then hands over to real sleep, where lift to wake takes over. The
 * nap is kept short because a dark-but-on screen still uses far more battery
 * than sleep.
 */
public class NapActivity extends Activity {
    static final String EXTRA_SECONDS = "nap_seconds";
    /** How long a tap can still wake the camera before it really sleeps. */
    static final int DEFAULT_SECONDS = 120;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean sleeping;

    private final Runnable sleepForReal = new Runnable() {
        @Override public void run() {
            sleeping = true;
            SleepActivity.sleepNow(NapActivity.this);
            finish();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WindowManager.LayoutParams attrs = getWindow().getAttributes();
        attrs.screenBrightness = 0f; // the system clamps this to its minimum backlight
        attrs.flags |= WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN;
        getWindow().setAttributes(attrs);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        final TextView hint = new TextView(this);
        hint.setText("Tap to wake");
        hint.setTextColor(0xFF555555);
        hint.setTextSize(16);
        hint.setGravity(Gravity.CENTER);
        root.addView(hint, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);
        root.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);

        // The hint is only there long enough to explain itself.
        handler.postDelayed(new Runnable() {
            @Override public void run() { hint.setVisibility(View.GONE); }
        }, 2500);

        int seconds = getIntent().getIntExtra(EXTRA_SECONDS, DEFAULT_SECONDS);
        handler.postDelayed(sleepForReal, Math.max(1, seconds) * 1000L);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) finish();
        return true; // the tap only wakes; it never reaches what was underneath
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getAction() == KeyEvent.ACTION_DOWN) finish();
        return true;
    }

    @Override
    protected void onPause() {
        super.onPause();
        // Left some other way (a notification, Home): don't sleep behind the user's back.
        handler.removeCallbacksAndMessages(null);
        if (!sleeping && !isFinishing()) finish();
    }
}
