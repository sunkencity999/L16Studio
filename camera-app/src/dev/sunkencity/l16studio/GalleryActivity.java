package dev.sunkencity.l16studio;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The home screen: every shot on the camera as a grid, newest first. */
public class GalleryActivity extends Activity {
    private static final int COLUMNS = 4;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService decoder = Executors.newFixedThreadPool(3);
    private List<Shots.Shot> shots = new ArrayList<>();
    private ShotAdapter adapter;
    private TextView summary;
    private TextView transferButton;
    private TextView transferAddress;
    private TextView empty;

    private final BroadcastReceiver transferChanged = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            refreshTransferState();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildLayout());
    }

    @Override
    protected void onResume() {
        super.onResume();
        registerReceiver(transferChanged, new IntentFilter(TransferService.ACTION_STATE));
        reload();
        refreshTransferState();
    }

    @Override
    protected void onPause() {
        super.onPause();
        unregisterReceiver(transferChanged);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        decoder.shutdownNow();
    }

    // ---- layout ---------------------------------------------------------

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(getColor(R.color.canvas));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(getColor(R.color.panel));
        bar.setPadding(dp(16), dp(8), dp(12), dp(8));

        LinearLayout titles = new LinearLayout(this);
        titles.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText("L16 Studio");
        title.setTextColor(getColor(R.color.text));
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        summary = new TextView(this);
        summary.setTextColor(getColor(R.color.text_dim));
        summary.setTextSize(13);
        summary.setSingleLine(true);
        summary.setEllipsize(android.text.TextUtils.TruncateAt.END);
        titles.addView(title);
        titles.addView(summary);
        bar.addView(titles, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));

        transferAddress = new TextView(this);
        transferAddress.setTextColor(getColor(R.color.accent));
        transferAddress.setTextSize(14);
        transferAddress.setPadding(0, 0, dp(12), 0);
        bar.addView(transferAddress);

        transferButton = pill("Wi-Fi transfer", false);
        transferButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { toggleTransfer(); }
        });
        bar.addView(transferButton);

        TextView camera = pill("Camera", true);
        camera.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { openCamera(); }
        });
        LinearLayout.LayoutParams cameraParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        cameraParams.leftMargin = dp(10);
        bar.addView(camera, cameraParams);
        root.addView(bar);

        FrameLayout body = new FrameLayout(this);
        GridView grid = new GridView(this);
        grid.setNumColumns(COLUMNS);
        grid.setHorizontalSpacing(dp(6));
        grid.setVerticalSpacing(dp(6));
        grid.setPadding(dp(8), dp(8), dp(8), dp(8));
        grid.setClipToPadding(false);
        grid.setSelector(new ColorDrawable(Color.TRANSPARENT));
        adapter = new ShotAdapter();
        grid.setAdapter(adapter);
        grid.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                Intent intent = new Intent(GalleryActivity.this, ViewerActivity.class);
                intent.putExtra(ViewerActivity.EXTRA_NAME, shots.get(position).name);
                startActivity(intent);
            }
        });
        grid.setOnItemLongClickListener(new AdapterView.OnItemLongClickListener() {
            @Override public boolean onItemLongClick(AdapterView<?> parent, View view, int position, long id) {
                confirmDelete(shots.get(position));
                return true;
            }
        });
        body.addView(grid);

        empty = new TextView(this);
        empty.setText("No shots yet.\nTap Camera to take one.");
        empty.setTextColor(getColor(R.color.text_dim));
        empty.setTextSize(18);
        empty.setGravity(Gravity.CENTER);
        body.addView(empty, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(body, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return root;
    }

    private TextView pill(String text, boolean filled) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(15);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setPadding(dp(16), dp(9), dp(16), dp(9));
        stylePill(view, filled);
        return view;
    }

    private void stylePill(TextView view, boolean filled) {
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(20));
        if (filled) {
            shape.setColor(getColor(R.color.accent));
            view.setTextColor(Color.BLACK);
        } else {
            shape.setColor(getColor(R.color.tile));
            view.setTextColor(getColor(R.color.text));
        }
        view.setBackground(shape);
    }

    // ---- data -----------------------------------------------------------

    private void reload() {
        shots = Shots.list();
        adapter.notifyDataSetChanged();
        long total = 0;
        for (Shots.Shot s : shots) total += s.size();
        summary.setText(shots.size() + (shots.size() == 1 ? " shot" : " shots")
                + "  ·  " + Shots.formatSize(total) + " used  ·  " + Shots.formatSize(Shots.freeBytes()) + " free");
        empty.setVisibility(shots.isEmpty() ? View.VISIBLE : View.GONE);
    }

    private void confirmDelete(final Shots.Shot shot) {
        new AlertDialog.Builder(this)
                .setTitle("Delete " + shot.name + "?")
                .setMessage("This removes the raw file and its preview from the camera. It can't be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface dialog, int which) {
                        if (!shot.delete()) {
                            Toast.makeText(GalleryActivity.this, "Couldn't delete " + shot.name, Toast.LENGTH_LONG).show();
                        }
                        reload();
                    }
                })
                .show();
    }

    private void openCamera() {
        Intent launch = getPackageManager().getLaunchIntentForPackage("light.co.lightcamera");
        if (launch == null) {
            Toast.makeText(this, "The Light camera app isn't installed.", Toast.LENGTH_LONG).show();
            return;
        }
        startActivity(launch);
    }

    // ---- Wi-Fi transfer -------------------------------------------------

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

    private void refreshTransferState() {
        boolean on = TransferService.isRunning();
        transferButton.setText(on ? "Wi-Fi transfer: on" : "Wi-Fi transfer");
        stylePill(transferButton, on);
        String address = on ? TransferService.localAddress(this) : null;
        transferAddress.setText(address == null ? "" : "http://" + address + ":" + TransferService.PORT);
    }

    // ---- grid -----------------------------------------------------------

    private final class ShotAdapter extends BaseAdapter {
        @Override public int getCount() { return shots.size(); }
        @Override public Object getItem(int position) { return shots.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            final Tile tile = convertView instanceof Tile ? (Tile) convertView : new Tile(GalleryActivity.this);
            final Shots.Shot shot = shots.get(position);
            tile.bound = shot.name;
            tile.label.setText(shot.label());

            Bitmap cached = Shots.cachedThumb(shot);
            tile.image.setImageBitmap(cached);
            if (cached == null) {
                final int width = Math.max(240, parent.getWidth() / COLUMNS);
                decoder.execute(new Runnable() {
                    @Override public void run() {
                        final Bitmap bitmap = Shots.loadThumb(shot, width);
                        ui.post(new Runnable() {
                            @Override public void run() {
                                // The tile may have been recycled for another shot meanwhile.
                                if (bitmap != null && shot.name.equals(tile.bound)) tile.image.setImageBitmap(bitmap);
                            }
                        });
                    }
                });
            }
            return tile;
        }
    }

    /** A 4:3 thumbnail with the shot number in the corner. */
    private final class Tile extends FrameLayout {
        final ImageView image;
        final TextView label;
        String bound;

        Tile(Context context) {
            super(context);
            setBackgroundColor(getColor(R.color.tile));
            image = new ImageView(context);
            image.setScaleType(ImageView.ScaleType.CENTER_CROP);
            addView(image, new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT));
            label = new TextView(context);
            label.setTextColor(Color.WHITE);
            label.setTextSize(12);
            label.setShadowLayer(4, 0, 1, Color.BLACK);
            label.setPadding(dp(6), dp(3), dp(6), dp(4));
            LayoutParams params = new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
            params.gravity = Gravity.BOTTOM | Gravity.START;
            addView(label, params);
        }

        @Override
        protected void onMeasure(int widthSpec, int heightSpec) {
            int width = MeasureSpec.getSize(widthSpec);
            super.onMeasure(widthSpec, MeasureSpec.makeMeasureSpec(width * 3 / 4, MeasureSpec.EXACTLY));
        }
    }
}
