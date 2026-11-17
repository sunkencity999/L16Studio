package dev.sunkencity.l16studio;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.AsyncTask;
import android.os.Bundle;
import android.text.format.DateFormat;
import android.util.TypedValue;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * One shot, full screen. Pinch or double-tap to zoom, drag to pan, swipe
 * sideways (when not zoomed) for the next or previous shot, tap to show or
 * hide the bar with the shot's details and Delete.
 */
public class ViewerActivity extends Activity {
    static final String EXTRA_NAME = "name";

    private List<Shots.Shot> shots;
    private int index;
    private ZoomView zoom;
    private View bar;
    private TextView title;
    private TextView details;
    private AsyncTask<Void, Void, Bitmap> loading;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        shots = Shots.list();
        String name = getIntent().getStringExtra(EXTRA_NAME);
        for (int i = 0; i < shots.size(); i++) {
            if (shots.get(i).name.equals(name)) index = i;
        }
        if (shots.isEmpty()) { finish(); return; }

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        zoom = new ZoomView(this);
        root.addView(zoom, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        bar = buildBar();
        FrameLayout.LayoutParams barParams = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        barParams.gravity = Gravity.TOP;
        root.addView(bar, barParams);
        setContentView(root);
        show(index);
    }

    @Override
    protected void onRestart() {
        super.onRestart();
        // Coming back from the editor: a saved edit is a new entry.
        String current = shots.isEmpty() ? null : shots.get(index).name;
        shots = Shots.list();
        if (shots.isEmpty()) { finish(); return; }
        index = 0;
        for (int i = 0; i < shots.size(); i++) {
            if (shots.get(i).name.equals(current)) index = i;
        }
        show(index);
    }

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    private View buildBar() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setBackgroundColor(0xB0000000);
        row.setPadding(dp(8), dp(8), dp(12), dp(8));

        TextView back = button("‹  Gallery", getColor(R.color.tile), getColor(R.color.text));
        back.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { finish(); }
        });
        row.addView(back);

        LinearLayout text = new LinearLayout(this);
        text.setOrientation(LinearLayout.VERTICAL);
        text.setPadding(dp(14), 0, 0, 0);
        title = new TextView(this);
        title.setTextColor(Color.WHITE);
        title.setTextSize(17);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        details = new TextView(this);
        details.setTextColor(getColor(R.color.text_dim));
        details.setTextSize(13);
        text.addView(title);
        text.addView(details);
        row.addView(text, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));

        TextView edit = button("Edit", getColor(R.color.accent), Color.BLACK);
        edit.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                Shots.Shot shot = shots.get(index);
                if (!shot.preview.exists()) {
                    Toast.makeText(ViewerActivity.this, "The camera hasn't written a preview for this shot yet.", Toast.LENGTH_LONG).show();
                    return;
                }
                android.content.Intent intent = new android.content.Intent(ViewerActivity.this, EditActivity.class);
                intent.putExtra(EXTRA_NAME, shot.name);
                startActivity(intent);
            }
        });
        LinearLayout.LayoutParams editParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        editParams.rightMargin = dp(10);
        row.addView(edit, editParams);

        TextView delete = button("Delete", getColor(R.color.danger), Color.WHITE);
        delete.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { confirmDelete(); }
        });
        row.addView(delete);
        return row;
    }

    private TextView button(String label, int background, int foreground) {
        TextView view = new TextView(this);
        view.setText(label);
        view.setTextSize(15);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setTextColor(foreground);
        view.setPadding(dp(16), dp(9), dp(16), dp(9));
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(20));
        shape.setColor(background);
        view.setBackground(shape);
        return view;
    }

    private void show(int newIndex) {
        index = Math.max(0, Math.min(shots.size() - 1, newIndex));
        final Shots.Shot shot = shots.get(index);
        title.setText(shot.name + "    " + (index + 1) + " of " + shots.size());
        String when = DateFormat.format("d MMM yyyy, HH:mm", shot.modified()).toString();
        details.setText(when + "  ·  " + (shot.raw.exists() ? "raw " + Shots.formatSize(shot.raw.length())
                : shot.isEdit() ? "edited copy" : "preview only"));

        if (loading != null) loading.cancel(false);
        // A quick small version first, then enough pixels for zooming.
        zoom.setBitmap(Shots.cachedThumb(shot), true);
        loading = new AsyncTask<Void, Void, Bitmap>() {
            @Override protected Bitmap doInBackground(Void... nothing) {
                return Shots.decode(shot.preview, 2400);
            }
            @Override protected void onPostExecute(Bitmap bitmap) {
                if (isCancelled()) return;
                if (bitmap != null) {
                    zoom.setBitmap(bitmap, false);
                } else if (!shot.preview.exists()) {
                    Toast.makeText(ViewerActivity.this, "The camera hasn't written a preview for this shot.", Toast.LENGTH_LONG).show();
                }
            }
        };
        loading.execute();
    }

    private void confirmDelete() {
        final Shots.Shot shot = shots.get(index);
        new AlertDialog.Builder(this)
                .setTitle("Delete " + shot.name + "?")
                .setMessage("This removes the raw file and its preview from the camera. It can't be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Delete", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface dialog, int which) {
                        if (!shot.delete()) {
                            Toast.makeText(ViewerActivity.this, "Couldn't delete " + shot.name, Toast.LENGTH_LONG).show();
                            return;
                        }
                        shots.remove(index);
                        if (shots.isEmpty()) finish(); else show(index);
                    }
                })
                .show();
    }

    /** Draws a bitmap with pinch zoom, pan, double-tap zoom and sideways-swipe paging. */
    private final class ZoomView extends View {
        private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        private final Matrix matrix = new Matrix();
        private Bitmap bitmap;
        private float fitScale = 1, scale = 1, panX, panY;
        private final ScaleGestureDetector pinch;
        private final GestureDetector gestures;

        ZoomView(Context context) {
            super(context);
            pinch = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
                @Override public boolean onScale(ScaleGestureDetector d) {
                    zoomAround(d.getFocusX(), d.getFocusY(), scale * d.getScaleFactor());
                    return true;
                }
            });
            gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
                @Override public boolean onDown(MotionEvent e) { return true; }

                @Override public boolean onScroll(MotionEvent a, MotionEvent b, float dx, float dy) {
                    if (isZoomed()) { panX -= dx; panY -= dy; clampAndDraw(); }
                    return true;
                }

                @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                    if (isZoomed() || Math.abs(vx) < Math.abs(vy) * 1.5f || Math.abs(vx) < 900) return false;
                    show(index + (vx < 0 ? 1 : -1));
                    return true;
                }

                @Override public boolean onDoubleTap(MotionEvent e) {
                    zoomAround(e.getX(), e.getY(), isZoomed() ? fitScale : fitScale * 3);
                    return true;
                }

                @Override public boolean onSingleTapConfirmed(MotionEvent e) {
                    bar.setVisibility(bar.getVisibility() == VISIBLE ? GONE : VISIBLE);
                    return true;
                }
            });
        }

        boolean isZoomed() { return scale > fitScale * 1.02f; }

        /** `resetView` refits; pass false when swapping in a sharper copy of the same shot. */
        void setBitmap(Bitmap next, boolean resetView) {
            float relative = fitScale > 0 ? scale / fitScale : 1;
            float cx = bitmap == null ? 0.5f : (getWidth() / 2f - panX) / (bitmap.getWidth() * scale);
            float cy = bitmap == null ? 0.5f : (getHeight() / 2f - panY) / (bitmap.getHeight() * scale);
            bitmap = next;
            if (bitmap == null || getWidth() == 0) { invalidate(); return; }
            fitScale = Math.min(getWidth() / (float) bitmap.getWidth(), getHeight() / (float) bitmap.getHeight());
            if (resetView) {
                scale = fitScale;
                cx = 0.5f; cy = 0.5f;
            } else {
                scale = fitScale * relative;
            }
            panX = getWidth() / 2f - cx * bitmap.getWidth() * scale;
            panY = getHeight() / 2f - cy * bitmap.getHeight() * scale;
            clampAndDraw();
        }

        @Override
        protected void onSizeChanged(int w, int h, int oldW, int oldH) {
            setBitmap(bitmap, true);
        }

        private void zoomAround(float fx, float fy, float target) {
            if (bitmap == null) return;
            float next = Math.max(fitScale, Math.min(fitScale * 12, target));
            float ratio = next / scale;
            panX = fx - (fx - panX) * ratio;
            panY = fy - (fy - panY) * ratio;
            scale = next;
            clampAndDraw();
        }

        private void clampAndDraw() {
            if (bitmap == null) return;
            float w = bitmap.getWidth() * scale, h = bitmap.getHeight() * scale;
            panX = w <= getWidth() ? (getWidth() - w) / 2 : Math.min(0, Math.max(getWidth() - w, panX));
            panY = h <= getHeight() ? (getHeight() - h) / 2 : Math.min(0, Math.max(getHeight() - h, panY));
            invalidate();
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            pinch.onTouchEvent(event);
            if (!pinch.isInProgress()) gestures.onTouchEvent(event);
            return true;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (bitmap == null) return;
            matrix.reset();
            matrix.postScale(scale, scale);
            matrix.postTranslate(panX, panY);
            canvas.drawBitmap(bitmap, matrix, paint);
        }
    }
}
