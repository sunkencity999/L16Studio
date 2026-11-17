package dev.sunkencity.l16studio;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.AsyncTask;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Every app on the camera that can be opened, alphabetically. Tap to open,
 * hold for the system's page about the app. "Home screen" opens the
 * setting that chooses between this home screen and the stock one.
 */
public class AppsActivity extends Activity {
    private static final class App {
        String label;
        Drawable icon;
        ComponentName component;
    }

    private final List<App> apps = new ArrayList<>();
    private AppAdapter adapter;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildLayout());
    }

    @Override
    protected void onResume() {
        super.onResume();
        load();
    }

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(getColor(R.color.canvas));

        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(getColor(R.color.panel));
        bar.setPadding(dp(8), dp(8), dp(12), dp(8));
        TextView back = pill("‹  Home");
        back.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { finish(); }
        });
        bar.addView(back);
        TextView title = new TextView(this);
        title.setText("All apps");
        title.setTextColor(getColor(R.color.text));
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setPadding(dp(14), 0, 0, 0);
        bar.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        TextView home = pill("Home screen…");
        home.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { chooseHome(); }
        });
        bar.addView(home);
        root.addView(bar);

        GridView grid = new GridView(this);
        grid.setNumColumns(6);
        grid.setVerticalSpacing(dp(4));
        grid.setPadding(dp(8), dp(8), dp(8), dp(8));
        grid.setClipToPadding(false);
        grid.setSelector(new ColorDrawable(0x22FFFFFF));
        adapter = new AppAdapter();
        grid.setAdapter(adapter);
        grid.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                open(apps.get(position));
            }
        });
        grid.setOnItemLongClickListener(new AdapterView.OnItemLongClickListener() {
            @Override public boolean onItemLongClick(AdapterView<?> parent, View view, int position, long id) {
                Intent info = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + apps.get(position).component.getPackageName()));
                start(info);
                return true;
            }
        });
        root.addView(grid, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return root;
    }

    private TextView pill(String text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(15);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setTextColor(getColor(R.color.text));
        view.setPadding(dp(16), dp(9), dp(16), dp(9));
        GradientDrawable shape = new GradientDrawable();
        shape.setCornerRadius(dp(20));
        shape.setColor(getColor(R.color.tile));
        view.setBackground(shape);
        return view;
    }

    private void load() {
        new AsyncTask<Void, Void, List<App>>() {
            @Override protected List<App> doInBackground(Void... nothing) {
                PackageManager pm = getPackageManager();
                Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
                List<App> found = new ArrayList<>();
                for (ResolveInfo info : pm.queryIntentActivities(launcher, 0)) {
                    App app = new App();
                    app.label = String.valueOf(info.loadLabel(pm));
                    app.icon = info.loadIcon(pm);
                    app.component = new ComponentName(info.activityInfo.packageName, info.activityInfo.name);
                    found.add(app);
                }
                Collections.sort(found, new Comparator<App>() {
                    @Override public int compare(App a, App b) { return a.label.compareToIgnoreCase(b.label); }
                });
                return found;
            }
            @Override protected void onPostExecute(List<App> found) {
                apps.clear();
                apps.addAll(found);
                adapter.notifyDataSetChanged();
            }
        }.execute();
    }

    private void open(App app) {
        Intent intent = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setComponent(app.component);
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        start(intent);
    }

    private void chooseHome() {
        if (!start(new Intent(Settings.ACTION_HOME_SETTINGS))) start(new Intent(Settings.ACTION_SETTINGS));
    }

    private boolean start(Intent intent) {
        try {
            startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException e) {
            Toast.makeText(this, "Couldn't open that.", Toast.LENGTH_SHORT).show();
            return false;
        }
    }

    private final class AppAdapter extends BaseAdapter {
        @Override public int getCount() { return apps.size(); }
        @Override public Object getItem(int position) { return apps.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            Cell cell = convertView instanceof Cell ? (Cell) convertView : new Cell(AppsActivity.this);
            App app = apps.get(position);
            cell.icon.setImageDrawable(app.icon);
            cell.label.setText(app.label);
            return cell;
        }
    }

    private final class Cell extends LinearLayout {
        final ImageView icon;
        final TextView label;

        Cell(Context context) {
            super(context);
            setOrientation(VERTICAL);
            setGravity(Gravity.CENTER_HORIZONTAL);
            setPadding(dp(4), dp(10), dp(4), dp(8));
            icon = new ImageView(context);
            addView(icon, new LayoutParams(dp(46), dp(46)));
            label = new TextView(context);
            label.setTextColor(getColor(R.color.text));
            label.setTextSize(12);
            label.setGravity(Gravity.CENTER);
            label.setMaxLines(2);
            label.setEllipsize(TextUtils.TruncateAt.END);
            label.setPadding(0, dp(5), 0, 0);
            addView(label, new LayoutParams(LayoutParams.MATCH_PARENT, dp(36)));
        }
    }
}
