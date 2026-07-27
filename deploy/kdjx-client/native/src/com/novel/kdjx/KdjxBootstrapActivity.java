package com.novel.kdjx;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ProgressBar;

/** Installs bundled resources off the UI thread before starting Cocos. */
public final class KdjxBootstrapActivity extends Activity {
    private static final String TAG = "KdjxBootstrap";

    private Intent launchIntent;
    private boolean installing;
    private boolean launched;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        launchIntent = new Intent(getIntent());
        showProgress();
        configureWindow();
        beginInstall();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        launchIntent = new Intent(intent);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    private void beginInstall() {
        if (installing || launched) return;
        installing = true;
        Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    BundledPatchInstaller.install(getApplicationContext());
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            launchGame();
                        }
                    });
                } catch (final RuntimeException error) {
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            showInstallError(error);
                        }
                    });
                }
            }
        }, "kdjx-bundled-patch");
        worker.start();
    }

    private void launchGame() {
        if (launched || isFinishing()
                || (Build.VERSION.SDK_INT >= 17 && isDestroyed())) {
            return;
        }
        launched = true;
        Intent game = launchIntent == null
                ? new Intent(this, SakuraGameActivity.class)
                : new Intent(launchIntent).setClass(this, SakuraGameActivity.class);
        game.setFlags(game.getFlags()
                & ~Intent.FLAG_ACTIVITY_NEW_TASK
                & ~Intent.FLAG_ACTIVITY_CLEAR_TASK
                & ~Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        game.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
        startActivity(game);
        overridePendingTransition(0, 0);
        finish();
    }

    private void showInstallError(RuntimeException error) {
        if (isFinishing()
                || (Build.VERSION.SDK_INT >= 17 && isDestroyed())) {
            return;
        }
        installing = false;
        Log.e(TAG, "Bundled patch bootstrap failed", error);
        new AlertDialog.Builder(this)
                .setTitle("\u8d44\u6e90\u5b89\u88c5\u5931\u8d25")
                .setMessage("\u8bf7\u68c0\u67e5\u5b58\u50a8\u7a7a\u95f4\u540e\u91cd\u8bd5\u3002")
                .setPositiveButton("\u91cd\u8bd5", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        beginInstall();
                    }
                })
                .setNegativeButton("\u9000\u51fa", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        finish();
                    }
                })
                .setCancelable(false)
                .show();
    }

    private void showProgress() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        ProgressBar progress = new ProgressBar(this);
        FrameLayout.LayoutParams layout = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER);
        root.addView(progress, layout);
        setContentView(root);
    }

    private void configureWindow() {
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams attributes = window.getAttributes();
            attributes.layoutInDisplayCutoutMode = Build.VERSION.SDK_INT >= 30
                    ? WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    : WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            window.setAttributes(attributes);
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
        }
        hideSystemBars();
    }

    private void hideSystemBars() {
        Window window = getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                controller.setSystemBarsBehavior(
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                controller.hide(WindowInsets.Type.systemBars());
            }
            return;
        }
        window.getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_FULLSCREEN);
    }
}
