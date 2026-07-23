import fs from "node:fs";

const [smaliPath, manifestPath] = process.argv.slice(2);
if (!smaliPath || !manifestPath) {
  throw new Error("usage: node patch-native.mjs <AppActivity.smali> <AndroidManifest.xml>");
}

function replaceOnce(source, label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

let smali = fs.readFileSync(smaliPath, "utf8").replace(/\r\n/g, "\n");

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


# virtual methods
`,
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

fs.writeFileSync(smaliPath, smali, "utf8");

let manifest = fs.readFileSync(manifestPath, "utf8").replace(/\r\n/g, "\n");
manifest = manifest.replace('android:debuggable="true"', 'android:debuggable="false"');
manifest = replaceOnce(
  manifest,
  "register Sakura deep link",
  `            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>`,
  `            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="sakura-modao" android:host="login"/>
            </intent-filter>`,
);
fs.writeFileSync(manifestPath, manifest, "utf8");
