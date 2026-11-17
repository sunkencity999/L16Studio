package dev.sunkencity.l16studio;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.AsyncTask;
import android.os.BatteryManager;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextClock;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * An optional home screen for the camera: the few things it is for, as
 * large targets. Camera on the left; Gallery, Wi-Fi transfer, Screen off
 * and All apps on the right. Everything else on the camera (the browser,
 * Settings, ...) is one tap away under All apps, and the stock home screen
 * stays installed: Android asks which one to use.
 */
public class HomeActivity extends Activity {
    private TextView status;
    private TextView gallerySub;
    private TextView transferSub;
    private ImageView galleryImage;
    private View transferTile;
    private int batteryPercent = -1;
    private boolean charging;
    private AsyncTask<Void, Void, Object[]> loading;

    private final BroadcastReceiver changed = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_BATTERY_CHANGED.equals(intent.getAction())) readBattery(intent);
            refresh();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildLayout());
        WakeService.startIfAllowed(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        IntentFilter filter = new IntentFilter(TransferService.ACTION_STATE);
        filter.addAction(Intent.ACTION_BATTERY_CHANGED);
        Intent battery = registerReceiver(changed, filter);
        if (battery != null) readBattery(battery);
        refresh();
    }

    @Override
    protected void onPause() {
        super.onPause();
        unregisterReceiver(changed);
        if (loading != null) loading.cancel(false);
    }

    /** This is the bottom of the stack: Back has nowhere to go. */
    @Override
    public void onBackPressed() {}

    private void readBattery(Intent intent) {
        int level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
        batteryPercent = level < 0 || scale <= 0 ? -1 : level * 100 / scale;
        int state = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
        charging = state == BatteryManager.BATTERY_STATUS_CHARGING || state == BatteryManager.BATTERY_STATUS_FULL;
    }

    // ---- layout ---------------------------------------------------------

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(getColor(R.color.canvas));
        root.setPadding(dp(12), dp(6), dp(12), dp(12));

        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(dp(4), 0, dp(4), dp(6));
        TextClock clock = new TextClock(this);
        // The status bar above already shows the time.
        clock.setFormat12Hour("EEEE d MMMM");
        clock.setFormat24Hour("EEEE d MMMM");
        clock.setTextColor(getColor(R.color.text));
        clock.setTextSize(17);
        clock.setTypeface(Typeface.DEFAULT_BOLD);
        top.addView(clock, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        status = new TextView(this);
        status.setTextColor(getColor(R.color.text_dim));
        status.setTextSize(14);
        top.addView(status);
        root.addView(top);

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.HORIZONTAL);

        // Camera: the biggest target on the screen.
        FrameLayout camera = tile(getColor(R.color.accent));
        camera.addView(new ApertureMark(this), new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        addLabels(camera, "Camera", "Take a picture", Color.BLACK, 0xB0000000);
        camera.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { openCamera(); }
        });
        body.addView(camera, cell(5, 0, 0));

        LinearLayout right = new LinearLayout(this);
        right.setOrientation(LinearLayout.VERTICAL);

        LinearLayout upper = new LinearLayout(this);
        FrameLayout gallery = tile(getColor(R.color.tile));
        galleryImage = new ImageView(this);
        galleryImage.setScaleType(ImageView.ScaleType.CENTER_CROP);
        gallery.addView(galleryImage, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        View scrim = new View(this);
        GradientDrawable fade = new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                new int[] {0xD0000000, 0x00000000});
        scrim.setBackground(fade);
        gallery.addView(scrim, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        gallery.setClipToOutline(true);
        gallerySub = addLabels(gallery, "Gallery", "", Color.WHITE, getColor(R.color.text));
        gallery.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                startActivity(new Intent(HomeActivity.this, GalleryActivity.class));
            }
        });
        upper.addView(gallery, cell(1, 0, 0));

        FrameLayout transfer = tile(getColor(R.color.tile));
        transferTile = transfer;
        transferSub = addLabels(transfer, "Transfer", "", getColor(R.color.text), getColor(R.color.text_dim));
        transfer.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { toggleTransfer(); }
        });
        upper.addView(transfer, cell(1, 10, 0));
        right.addView(upper, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        LinearLayout lower = new LinearLayout(this);
        FrameLayout sleep = tile(getColor(R.color.tile));
        addLabels(sleep, "Screen off", "Hold to sleep at once", getColor(R.color.text), getColor(R.color.text_dim));
        sleep.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { SleepActivity.sleep(HomeActivity.this); }
        });
        sleep.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) {
                if (SleepActivity.isAllowed(HomeActivity.this)) SleepActivity.sleepNow(HomeActivity.this);
                else SleepActivity.sleep(HomeActivity.this);
                return true;
            }
        });
        lower.addView(sleep, cell(1, 0, 0));

        FrameLayout apps = tile(getColor(R.color.tile));
        addLabels(apps, "All apps", "Firefox, Settings…", getColor(R.color.text), getColor(R.color.text_dim));
        apps.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                startActivity(new Intent(HomeActivity.this, AppsActivity.class));
            }
        });
        lower.addView(apps, cell(1, 10, 0));
        LinearLayout.LayoutParams lowerParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1);
        lowerParams.topMargin = dp(10);
        right.addView(lower, lowerParams);

        body.addView(right, cell(7, 10, 0));
        root.addView(body, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return root;
    }

    private LinearLayout.LayoutParams cell(float weight, int leftDp, int topDp) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight);
        params.leftMargin = dp(leftDp);
        params.topMargin = dp(topDp);
        return params;
    }

    private FrameLayout tile(int color) {
        FrameLayout tile = new FrameLayout(this);
        tile.setBackground(shape(color));
        tile.setForeground(getDrawable(resolve(android.R.attr.selectableItemBackground)));
        return tile;
    }

    private GradientDrawable shape(int color) {
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(14));
        shape.setColor(color);
        return shape;
    }

    private int resolve(int attribute) {
        TypedValue value = new TypedValue();
        getTheme().resolveAttribute(attribute, value, true);
        return value.resourceId;
    }

    /** A title and a line under it, bottom left of a tile. Returns the second line. */
    private TextView addLabels(FrameLayout tile, String title, String sub, int titleColor, int subColor) {
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(dp(14), dp(10), dp(14), dp(12));
        TextView big = new TextView(this);
        big.setText(title);
        big.setTextColor(titleColor);
        big.setTextSize(22);
        big.setTypeface(Typeface.DEFAULT_BOLD);
        TextView small = new TextView(this);
        small.setText(sub);
        small.setTextColor(subColor);
        small.setTextSize(13);
        small.setSingleLine(true);
        column.addView(big);
        column.addView(small);
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.gravity = Gravity.BOTTOM;
        tile.addView(column, params);
        return small;
    }

    /** The camera's lens cluster, suggested with a few rings. */
    private static final class ApertureMark extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        ApertureMark(Context context) {
            super(context);
            paint.setColor(0x30000000);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth(), h = getHeight();
            float unit = Math.min(w, h) / 11.5f;
            float cx = w * 0.5f, cy = h * 0.40f;
            float[][] lenses = {
                {0, 0, 1.5f}, {-2.6f, -1.3f, 1.0f}, {2.5f, -1.6f, 1.15f}, {-1.9f, 2.0f, 1.15f},
                {1.9f, 2.2f, 0.9f}, {3.9f, 0.7f, 0.75f}, {-0.2f, -3.0f, 0.75f}, {-4.0f, 0.9f, 0.7f},
            };
            for (float[] lens : lenses) {
                canvas.drawCircle(cx + lens[0] * unit, cy + lens[1] * unit, lens[2] * unit, paint);
            }
        }
    }

    // ---- state ----------------------------------------------------------

    private void refresh() {
        boolean on = TransferService.isRunning();
        String address = on ? TransferService.localAddress(this) : null;
        transferSub.setText(!on ? "Wi-Fi off  ·  tap to start"
                : address == null ? "On" : "On  ·  " + address + ":" + TransferService.PORT);
        transferSub.setTextColor(getColor(on ? R.color.accent : R.color.text_dim));
        GradientDrawable shape = shape(getColor(R.color.tile));
        if (on) shape.setStroke(dp(2), getColor(R.color.accent));
        transferTile.setBackground(shape);

        if (loading != null) loading.cancel(false);
        loading = new AsyncTask<Void, Void, Object[]>() {
            @Override protected Object[] doInBackground(Void... nothing) {
                List<Shots.Shot> shots = Shots.list();
                Bitmap latest = null;
                for (Shots.Shot shot : shots) {
                    if (shot.preview.exists()) { latest = Shots.loadThumb(shot, 480); break; }
                }
                return new Object[] {shots.size(), latest, Shots.freeBytes()};
            }
            @Override protected void onPostExecute(Object[] result) {
                if (isCancelled()) return;
                int count = (Integer) result[0];
                gallerySub.setText(count == 0 ? "No shots yet" : count + (count == 1 ? " shot" : " shots"));
                galleryImage.setImageBitmap((Bitmap) result[1]);
                String battery = batteryPercent < 0 ? "" : (charging ? "Charging " : "Battery ") + batteryPercent + "%  ·  ";
                status.setText(battery + Shots.formatSize((Long) result[2]) + " free");
            }
        };
        loading.execute();
    }

    private void openCamera() {
        Intent launch = getPackageManager().getLaunchIntentForPackage("light.co.lightcamera");
        if (launch == null) {
            Toast.makeText(this, "The Light camera app isn't installed.", Toast.LENGTH_LONG).show();
            return;
        }
        startActivity(launch);
    }

    private void toggleTransfer() {
        Intent service = new Intent(this, TransferService.class);
        if (TransferService.isRunning()) {
            stopService(service);
        } else if (TransferService.localAddress(this) == null) {
            Toast.makeText(this, "Connect the camera to Wi-Fi first.", Toast.LENGTH_LONG).show();
        } else {
            startService(service);
        }
    }
}
