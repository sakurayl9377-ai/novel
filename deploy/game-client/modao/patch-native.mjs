import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function replaceOnce(source, label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

export function patchNativeSmali(input) {
let smali = input.replace(/\r\n/g, "\n");

smali = replaceOnce(
  smali,
  "capture replacement launch intent",
  "    invoke-super {p0, p1}, Lcom/cocos/lib/CocosActivity;->onNewIntent(Landroid/content/Intent;)V\n\n    .line 163",
  `    invoke-super {p0, p1}, Lcom/cocos/lib/CocosActivity;->onNewIntent(Landroid/content/Intent;)V

    invoke-virtual {p0, p1}, Lcom/cocos/game/AppActivity;->setIntent(Landroid/content/Intent;)V

    .line 163`,
);

smali = replaceOnce(
  smali,
  "pause network queue before backgrounding",
  `.method protected onPause()V
    .locals 1

    .line 147
    invoke-super {p0}, Lcom/cocos/lib/CocosActivity;->onPause()V`,
  `.method protected onPause()V
    .locals 1

    sget-boolean v0, Lcom/cocos/game/App;->mIsInitedCocosJs:Z

    if-eqz v0, :sakura_pause_done

    invoke-virtual {p0}, Lcom/cocos/game/AppActivity;->gamePause()V

    :sakura_pause_done
    .line 147
    invoke-super {p0}, Lcom/cocos/lib/CocosActivity;->onPause()V`,
);

smali = replaceOnce(
  smali,
  "resume network queue and probe connection",
  `    invoke-virtual {v0}, Lcom/cocos/game/AppSdk;->onResume()V

    .line 143
    return-void
.end method`,
  `    invoke-virtual {v0}, Lcom/cocos/game/AppSdk;->onResume()V

    sget-boolean v0, Lcom/cocos/game/App;->mIsInitedCocosJs:Z

    if-eqz v0, :sakura_resume_done

    invoke-virtual {p0}, Lcom/cocos/game/AppActivity;->gameResume()V

    :sakura_resume_done
    .line 143
    return-void
.end method`,
);

smali = replaceOnce(
  smali,
  "add one-shot Sakura intent reader",
  "\n\n# virtual methods\n",
  `

.method public static takeSakuraExtra(Ljava/lang/String;)Ljava/lang/String;
    .locals 4

    sget-object v0, Lcom/cocos/game/AppActivity;->app:Lcom/cocos/game/AppActivity;

    if-eqz v0, :sakura_extra_empty

    invoke-virtual {v0}, Lcom/cocos/game/AppActivity;->getIntent()Landroid/content/Intent;

    move-result-object v1

    if-eqz v1, :sakura_extra_empty

    invoke-virtual {v1}, Landroid/content/Intent;->getExtras()Landroid/os/Bundle;

    move-result-object v2

    if-eqz v2, :sakura_extra_empty

    invoke-virtual {v2, p0}, Landroid/os/Bundle;->get(Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v3

    if-eqz v3, :sakura_extra_empty

    invoke-static {v3}, Ljava/lang/String;->valueOf(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v1, p0}, Landroid/content/Intent;->removeExtra(Ljava/lang/String;)V

    return-object v3

    :sakura_extra_empty
    const-string v0, ""

    return-object v0
.end method

.method public static createSakuraRequestId()Ljava/lang/String;
    .locals 3

    invoke-static {}, Ljava/util/UUID;->randomUUID()Ljava/util/UUID;

    move-result-object v0

    invoke-virtual {v0}, Ljava/util/UUID;->toString()Ljava/lang/String;

    move-result-object v0

    const-string v1, "-"

    const-string v2, ""

    invoke-virtual {v0, v1, v2}, Ljava/lang/String;->replace(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;

    move-result-object v0

    return-object v0
.end method


# virtual methods
`,
);

smali = replaceOnce(
  smali,
  "handle an unavailable Sakura app",
  `    invoke-direct {v2, v3, v4}, Landroid/content/Intent;-><init>(Ljava/lang/String;Landroid/net/Uri;)V

    invoke-virtual {v1, v2}, Lcom/cocos/game/AppActivity;->startActivity(Landroid/content/Intent;)V

    .line 670
    new-instance v1, Lorg/json/JSONObject;`,
  `    invoke-direct {v2, v3, v4}, Landroid/content/Intent;-><init>(Ljava/lang/String;Landroid/net/Uri;)V

    invoke-virtual {v4}, Landroid/net/Uri;->getScheme()Ljava/lang/String;

    move-result-object v3

    const-string v4, "sakura-novel"

    invoke-virtual {v4, v3}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v3

    if-eqz v3, :sakura_open_unscoped

    const-string v3, "com.novel.novel_app"

    invoke-virtual {v2, v3}, Landroid/content/Intent;->setPackage(Ljava/lang/String;)Landroid/content/Intent;

    :sakura_open_unscoped
    :try_start_sakura_open
    invoke-virtual {v1, v2}, Lcom/cocos/game/AppActivity;->startActivity(Landroid/content/Intent;)V
    :try_end_sakura_open
    .catch Landroid/content/ActivityNotFoundException; {:try_start_sakura_open .. :try_end_sakura_open} :catch_sakura_open

    goto :sakura_open_success

    :catch_sakura_open
    move-exception v1

    const-string v1, "{\\"ok\\":false,\\"error\\":\\"activity_not_found\\"}"

    return-object v1

    :sakura_open_success
    .line 670
    new-instance v1, Lorg/json/JSONObject;`,
);

smali = replaceOnce(
  smali,
  "add resume event",
  ".method public gameSendEvent(Ljava/util/Map;)V\n",
  `.method public gameResume()V
    .locals 3

    new-instance v0, Ljava/util/HashMap;

    invoke-direct {v0}, Ljava/util/HashMap;-><init>()V

    const-string v1, "name"

    const-string v2, "resume"

    invoke-interface {v0, v1, v2}, Ljava/util/Map;->put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;

    invoke-virtual {p0, v0}, Lcom/cocos/game/AppActivity;->gameSendEvent(Ljava/util/Map;)V

    return-void
.end method

.method public gameSendEvent(Ljava/util/Map;)V
`,
);

return smali;
}

export function patchNativeManifest(input) {
let manifest = input.replace(/\r\n/g, "\n");
manifest = manifest.replace('android:debuggable="true"', 'android:debuggable="false"');
const launcherFilter = `            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>`;
const legacySakuraFilter = `
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="sakura-modao" android:host="login"/>
            </intent-filter>`;
const callbackFilter = `
            <intent-filter>
                <action android:name="com.you91.fish.lucky.SAKURA_SSO_CALLBACK"/>
                <category android:name="android.intent.category.DEFAULT"/>
            </intent-filter>`;
manifest = replaceOnce(
  manifest,
  "register Sakura deep link",
  launcherFilter,
  launcherFilter +
    (manifest.includes('android:scheme="sakura-modao"')
      ? callbackFilter
      : legacySakuraFilter + callbackFilter),
);
return manifest;
}

function isDirectInvocation() {
  if (!process.argv[1]) return false;
  return pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
}

if (isDirectInvocation()) {
  const [smaliPath, manifestPath] = process.argv.slice(2);
  if (!smaliPath || !manifestPath) {
    throw new Error(
      "usage: node patch-native.mjs <AppActivity.smali> <AndroidManifest.xml>",
    );
  }
  const smali = fs.readFileSync(smaliPath, "utf8");
  const manifest = fs.readFileSync(manifestPath, "utf8");
  fs.writeFileSync(smaliPath, patchNativeSmali(smali), "utf8");
  fs.writeFileSync(manifestPath, patchNativeManifest(manifest), "utf8");
}
