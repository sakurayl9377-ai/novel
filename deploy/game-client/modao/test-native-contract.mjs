import assert from "node:assert/strict";
import fs from "node:fs";

import {
  patchNativeManifest,
  patchNativeSmali,
} from "./patch-native.mjs";

const smaliFixture = `.method protected onNewIntent(Landroid/content/Intent;)V
    invoke-super {p0, p1}, Lcom/cocos/lib/CocosActivity;->onNewIntent(Landroid/content/Intent;)V

    .line 163
.end method

.method protected onPause()V
    .locals 1

    .line 147
    invoke-super {p0}, Lcom/cocos/lib/CocosActivity;->onPause()V
.end method

.method protected onResume()V
    invoke-virtual {v0}, Lcom/cocos/game/AppSdk;->onResume()V

    .line 143
    return-void
.end method

.method public static openPayUrl(Lorg/json/JSONObject;)Ljava/lang/String;
    invoke-direct {v2, v3, v4}, Landroid/content/Intent;-><init>(Ljava/lang/String;Landroid/net/Uri;)V

    invoke-virtual {v1, v2}, Lcom/cocos/game/AppActivity;->startActivity(Landroid/content/Intent;)V

    .line 670
    new-instance v1, Lorg/json/JSONObject;
.end method


# virtual methods
.method public gameSendEvent(Ljava/util/Map;)V
.end method
`;

const patchedSmali = patchNativeSmali(smaliFixture);
assert.ok(patchedSmali.includes("createSakuraRequestId()Ljava/lang/String;"));
assert.ok(patchedSmali.includes("takeSakuraExtra(Ljava/lang/String;)"));
assert.ok(patchedSmali.includes("gameResume()V"));
assert.ok(patchedSmali.includes('const-string v3, "com.novel.novel_app"'));
assert.ok(
  patchedSmali.includes(
    ".catch Landroid/content/ActivityNotFoundException; {:try_start_sakura_open .. :try_end_sakura_open} :catch_sakura_open",
  ),
);
assert.ok(
  patchedSmali.includes(
    'const-string v1, "{\\"ok\\":false,\\"error\\":\\"activity_not_found\\"}"',
  ),
);

const launcher = `            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>`;
const manifestFixture = `<manifest>
    <application android:debuggable="true">
        <activity>
${launcher}
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:host="login" android:scheme="sakura-modao"/>
            </intent-filter>
        </activity>
    </application>
</manifest>`;
const patchedManifest = patchNativeManifest(manifestFixture);
assert.ok(patchedManifest.includes('android:debuggable="false"'));
assert.equal(patchedManifest.split('android:scheme="sakura-modao"').length - 1, 1);
assert.equal(
  patchedManifest.split(
    'android:name="com.you91.fish.lucky.SAKURA_SSO_CALLBACK"',
  ).length - 1,
  1,
);

const javaReference = fs.readFileSync(
  new URL("./SakuraBridge.java", import.meta.url),
  "utf8",
);
assert.ok(javaReference.includes("ACTION_SSO_CALLBACK"));
assert.ok(javaReference.includes("EXTRA_SSO_REQUEST_ID"));
assert.ok(javaReference.includes('appendQueryParameter("requestId", requestId)'));
assert.ok(!javaReference.includes('getQueryParameter("ticket")'));

console.log("native Sakura callback contract tests passed");
