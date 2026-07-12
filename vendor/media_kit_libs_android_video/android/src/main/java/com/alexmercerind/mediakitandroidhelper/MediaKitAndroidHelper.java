package com.alexmercerind.mediakitandroidhelper;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.Keep;

@Keep
public class MediaKitAndroidHelper {
    static {
        System.loadLibrary("mediakitandroidhelper");
    }

    private static Context applicationContext;

    public static native long newGlobalObjectRef(Object object);
    public static native void deleteGlobalObjectRef(long ref);
    public static native String copyAssetToFilesDir(String assetName);
    private static native void setApplicationContextNative(Context context);
    public static native int openFileDescriptorNative(String uri);

    public static void setApplicationContextJava(Context context) {
        applicationContext = context.getApplicationContext();
        setApplicationContextNative(applicationContext);
    }

    public static int openFileDescriptorJava(String uri) {
        try {
            return applicationContext
                .getContentResolver()
                .openFileDescriptor(Uri.parse(uri), "r")
                .detachFd();
        } catch (Throwable error) {
            return -1;
        }
    }
}
