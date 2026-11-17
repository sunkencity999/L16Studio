package dev.sunkencity.l16studio;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.AsyncTask;
import android.os.Bundle;
import android.renderscript.RenderScript;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * The editor. Pick a look along the bottom (each one starts from an automatic
 * correction measured from this photo), fine-tune it with the sliders, hold
 * the picture to compare with the original, and save a full-resolution copy
 * next to the shot. The original preview and the raw file are never changed.
 */
public class EditActivity extends Activity {
    /** Longest side of the working preview. */
    private static final int PREVIEW_WIDTH = 1600;

    private Shots.Shot shot;
    private RenderScript rs;
    private Bitmap original;       // working-size copy of the camera's preview
    private Bitmap edited;
    private Look measured = new Look();
    private Look look = new Look();
    private Look.Style style = Look.Style.AUTO;

    private ImageView image;
    private LinearLayout styleRow;
    private View sliderPanel;
    private TextView adjustButton;
    private final List<Slider> sliders = new ArrayList<>();
    private boolean rendering, renderAgain, saving;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        shot = Shots.find(getIntent().getStringExtra(ViewerActivity.EXTRA_NAME));
        if (shot == null || !shot.preview.exists()) { finish(); return; }
        rs = RenderScript.create(this);
        setContentView(buildLayout());

        new AsyncTask<Void, Void, Bitmap>() {
            @Override protected Bitmap doInBackground(Void... nothing) {
                Bitmap bitmap = Shots.decode(shot.preview, PREVIEW_WIDTH, Bitmap.Config.ARGB_8888);
                if (bitmap != null) {
                    Bitmap sample = Bitmap.createScaledBitmap(bitmap, 320, Math.max(1, 320 * bitmap.getHeight() / bitmap.getWidth()), true);
                    measured = Look.analyse(sample);
                }
                return bitmap;
            }
            @Override protected void onPostExecute(Bitmap bitmap) {
                if (bitmap == null) {
                    Toast.makeText(EditActivity.this, "Couldn't open this picture.", Toast.LENGTH_LONG).show();
                    finish();
                    return;
                }
                original = bitmap;
                choose(Look.Style.AUTO);
            }
        }.execute();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (rs != null) rs.destroy();
    }

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    // ---- layout ---------------------------------------------------------

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);

        // Top bar.
        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(getColor(R.color.panel));
        bar.setPadding(dp(8), dp(6), dp(12), dp(6));
        TextView cancel = pill("Cancel", getColor(R.color.tile), getColor(R.color.text));
        cancel.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { finish(); }
        });
        bar.addView(cancel);
        TextView title = new TextView(this);
        title.setText("Edit " + shot.label() + "      hold the picture to compare");
        title.setTextColor(getColor(R.color.text_dim));
        title.setTextSize(14);
        title.setPadding(dp(14), 0, 0, 0);
        bar.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        adjustButton = pill("Adjust", getColor(R.color.tile), getColor(R.color.text));
        adjustButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                boolean show = sliderPanel.getVisibility() != View.VISIBLE;
                sliderPanel.setVisibility(show ? View.VISIBLE : View.GONE);
                stylePill(adjustButton, show ? getColor(R.color.text) : getColor(R.color.tile), show ? Color.BLACK : getColor(R.color.text));
            }
        });
        LinearLayout.LayoutParams gap = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        gap.rightMargin = dp(10);
        bar.addView(adjustButton, gap);
        TextView save = pill("Save copy", getColor(R.color.accent), Color.BLACK);
        save.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { save(); }
        });
        bar.addView(save);
        root.addView(bar);

        // Picture, with the slider panel beside it.
        LinearLayout middle = new LinearLayout(this);
        middle.setOrientation(LinearLayout.HORIZONTAL);
        image = new ImageView(this);
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        image.setOnTouchListener(new View.OnTouchListener() {
            @Override public boolean onTouch(View v, MotionEvent event) {
                // Hold to see the untouched preview; release to see the edit.
                if (original == null) return true;
                int action = event.getActionMasked();
                if (action == MotionEvent.ACTION_DOWN) image.setImageBitmap(original);
                if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                    image.setImageBitmap(edited != null ? edited : original);
                }
                return true;
            }
        });
        middle.addView(image, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1));
        sliderPanel = buildSliders();
        sliderPanel.setVisibility(View.GONE);
        middle.addView(sliderPanel, new LinearLayout.LayoutParams(dp(250), ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(middle, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        // Looks.
        HorizontalScrollView scroller = new HorizontalScrollView(this);
        scroller.setHorizontalScrollBarEnabled(false);
        scroller.setBackgroundColor(getColor(R.color.panel));
        styleRow = new LinearLayout(this);
        styleRow.setPadding(dp(8), dp(8), dp(8), dp(8));
        for (final Look.Style s : Look.Style.values()) {
            TextView chip = pill(s.label, getColor(R.color.tile), getColor(R.color.text));
            chip.setTag(s);
            chip.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { choose(s); }
            });
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            p.rightMargin = dp(8);
            styleRow.addView(chip, p);
        }
        scroller.addView(styleRow);
        root.addView(scroller);
        return root;
    }

    private TextView pill(String text, int background, int foreground) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(15);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setPadding(dp(16), dp(8), dp(16), dp(8));
        stylePill(view, background, foreground);
        return view;
    }

    private void stylePill(TextView view, int background, int foreground) {
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(20));
        shape.setColor(background);
        view.setBackground(shape);
        view.setTextColor(foreground);
    }

    /** One labelled slider bound to a field of the current look. */
    private abstract class Slider {
        final String name;
        final float min, max;
        SeekBar bar;
        TextView value;

        Slider(String name, float min, float max) { this.name = name; this.min = min; this.max = max; }
        abstract float get(Look l);
        abstract void set(Look l, float v);

        void sync() {
            float v = get(look);
            bar.setProgress(Math.round((v - min) / (max - min) * 200));
            value.setText(String.format("%+.2f", v));
        }
    }

    private View buildSliders() {
        sliders.add(new Slider("Exposure", -1.5f, 1.5f) {
            float get(Look l) { return l.exposure; } void set(Look l, float v) { l.exposure = v; } });
        sliders.add(new Slider("Contrast", -1, 1) {
            float get(Look l) { return l.contrast; } void set(Look l, float v) { l.contrast = v; } });
        sliders.add(new Slider("Highlights", -1, 1) {
            float get(Look l) { return l.highlights; } void set(Look l, float v) { l.highlights = v; } });
        sliders.add(new Slider("Shadows", -1, 1) {
            float get(Look l) { return l.shadows; } void set(Look l, float v) { l.shadows = v; } });
        sliders.add(new Slider("Colour", 0, 2) {
            float get(Look l) { return l.saturation; } void set(Look l, float v) { l.saturation = v; } });
        sliders.add(new Slider("Warmth", -1, 1) {
            float get(Look l) { return l.warmth; } void set(Look l, float v) { l.warmth = v; } });
        sliders.add(new Slider("Fade", 0, 1) {
            float get(Look l) { return l.fade; } void set(Look l, float v) { l.fade = v; } });
        sliders.add(new Slider("Sharpen", 0, 1) {
            float get(Look l) { return l.sharpen; } void set(Look l, float v) { l.sharpen = v; } });

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(dp(12), dp(8), dp(12), dp(8));
        for (final Slider slider : sliders) {
            LinearLayout heading = new LinearLayout(this);
            TextView label = new TextView(this);
            label.setText(slider.name);
            label.setTextColor(getColor(R.color.text));
            label.setTextSize(13);
            heading.addView(label, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            slider.value = new TextView(this);
            slider.value.setTextColor(getColor(R.color.text_dim));
            slider.value.setTextSize(13);
            heading.addView(slider.value);
            column.addView(heading);

            slider.bar = new SeekBar(this);
            slider.bar.setMax(200);
            slider.bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                    if (!fromUser) return;
                    float v = slider.min + (slider.max - slider.min) * progress / 200f;
                    slider.set(look, v);
                    slider.value.setText(String.format("%+.2f", v));
                    render();
                }
                @Override public void onStartTrackingTouch(SeekBar bar) {}
                @Override public void onStopTrackingTouch(SeekBar bar) {}
            });
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            p.bottomMargin = dp(4);
            column.addView(slider.bar, p);
        }
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(getColor(R.color.panel));
        scroll.addView(column);
        return scroll;
    }

    // ---- editing --------------------------------------------------------

    private void choose(Look.Style next) {
        style = next;
        look = Look.forStyle(next, measured);
        for (int i = 0; i < styleRow.getChildCount(); i++) {
            TextView chip = (TextView) styleRow.getChildAt(i);
            boolean on = chip.getTag() == next;
            stylePill(chip, on ? getColor(R.color.accent) : getColor(R.color.tile), on ? Color.BLACK : getColor(R.color.text));
        }
        for (Slider slider : sliders) slider.sync();
        render();
    }

    /** Renders the preview off the UI thread; coalesces rapid slider changes. */
    private void render() {
        if (original == null) return;
        if (rendering) { renderAgain = true; return; }
        rendering = true;
        final Look snapshot = look.copy();
        // The preview is about half the saved width, so halve the sharpening
        // to show roughly what the full-size result will look like.
        final float sharpenScale = original.getWidth() / 3328f;
        new AsyncTask<Void, Void, Bitmap>() {
            @Override protected Bitmap doInBackground(Void... nothing) {
                return snapshot.render(rs, original, sharpenScale);
            }
            @Override protected void onPostExecute(Bitmap bitmap) {
                rendering = false;
                if (isFinishing()) return;
                edited = bitmap;
                image.setImageBitmap(bitmap);
                if (renderAgain) { renderAgain = false; render(); }
            }
        }.execute();
    }

    private void save() {
        if (saving || original == null) return;
        saving = true;
        Toast.makeText(this, "Saving…", Toast.LENGTH_SHORT).show();
        final Look snapshot = look.copy();
        final String styleName = style == Look.Style.ORIGINAL ? "" : "_" + style.label;
        new AsyncTask<Void, Void, File>() {
            @Override protected File doInBackground(Void... nothing) {
                // Full resolution from the camera's preview.
                Bitmap full = Shots.decode(shot.preview, 100000, Bitmap.Config.ARGB_8888);
                if (full == null) return null;
                Bitmap result = snapshot.render(rs, full, 1f);
                full.recycle();

                // "L16_00002_edit_Vivid.jpg", then _2, _3... if taken.
                String base = shot.name.replaceAll("_edit.*$", "") + "_edit" + styleName;
                File target = new File(Shots.FOLDER, base + ".jpg");
                for (int n = 2; target.exists(); n++) target = new File(Shots.FOLDER, base + "_" + n + ".jpg");
                try (FileOutputStream out = new FileOutputStream(target)) {
                    result.compress(Bitmap.CompressFormat.JPEG, 95, out);
                } catch (IOException e) {
                    target.delete();
                    return null;
                } finally {
                    result.recycle();
                }
                return target;
            }
            @Override protected void onPostExecute(File file) {
                saving = false;
                if (file == null) {
                    Toast.makeText(EditActivity.this, "Couldn't save the edit.", Toast.LENGTH_LONG).show();
                    return;
                }
                // Let other apps (the stock gallery, file transfer) see it.
                sendBroadcast(new Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(file)));
                Toast.makeText(EditActivity.this, "Saved " + file.getName(), Toast.LENGTH_LONG).show();
                finish();
            }
        }.execute();
    }
}
