package com.alexmercerind.media_kit_libs_android_video;

import android.util.Log;
import androidx.annotation.NonNull;
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

public class MediaKitLibsAndroidVideoPlugin implements FlutterPlugin {
    static {
        try {
            System.loadLibrary("mpv");
        } catch (Throwable error) {
            Log.e("media_kit", "Unable to preload libmpv", error);
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        MediaKitAndroidHelper.setApplicationContextJava(binding.getApplicationContext());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        // No Dart channel or native resource is owned by this registrar.
    }
}
