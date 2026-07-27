#!/usr/bin/env python3
"""Build the Sakura KDJX hot update and an unsigned, repacked bootstrap APK.

The script deliberately does not know any signing key, password, SSH host, or
deployment credential. Signing happens later on the download server after the
generated output has passed the address audit.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Iterable
from urllib.parse import unquote, urlparse
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parent
NATIVE_SOURCE = ROOT / "native" / "src" / "com" / "novel" / "kdjx" / "SakuraGameActivity.java"
PAYMENT_RECOVERY_SOURCE = NATIVE_SOURCE.with_name("PaymentRecovery.java")
ANDROID_NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID_NS)
ANDROID = "{%s}" % ANDROID_NS

OWNED_GAME_HOST = "49.232.137.85"
OWNED_DOWNLOAD_HOSTS = {"novel.kxhub.xyz"}
DEFAULT_GAME_ORIGIN = f"https://{OWNED_GAME_HOST}"
DEFAULT_API_ORIGIN = f"{DEFAULT_GAME_ORIGIN}/novel-api"
DEFAULT_DOWNLOAD_BASE = "https://novel.kxhub.xyz/games/kdjx/hot"
MAX_ANDROID_VERSION_CODE = 2_100_000_000

FORBIDDEN_ENDPOINTS = (
    "192.168.",
    "202.189.12.86",
    "107.151.203.236",
    "123.207.108.22",
    "172.81.227.66",
    "212.64.40.75",
    "123.com",
    "oss.kuyangsh.cn",
    "tiancigame.cn",
    "qingshangame.com",
    "adt.cpatrk.net",
    "me.cpatrk.net",
    "cloud.xdrig.com",
    "i.tddmp.com",
    "talkingdata.net",
    "bugly.qq.com",
    "rqd.uu.qq.com",
    "qm.qq.com",
    "116.196.67.142",
    "116.196.84.232",
)

# The final client has exactly two network origins: the KDJX game listener and
# the HTTPS download host. Metadata URL literals are intentionally handled by
# a separate, path-scoped rule below rather than globally allowing their hosts.
OWNED_CLIENT_URL_HOSTS = frozenset({
    OWNED_GAME_HOST,
    *OWNED_DOWNLOAD_HOSTS,
})
METADATA_URL_LITERALS = frozenset({
    "https://android.googlesource.com/toolchain/clang",
    "https://android.googlesource.com/toolchain/llvm",
    "https://android.googlesource.com/toolchain/llvm-project",
    "https://curl.haxx.se/docs/http-cookies.html",
    "http://ns.adobe.com/bwf/bext/1.0/",
    "http://ns.adobe.com/creatorAtom/1.0/",
    "http://ns.adobe.com/ixml/1.0/",
    "http://ns.adobe.com/xap/1.0/",
    "http://ns.adobe.com/xap/1.0/mm/",
    "http://ns.adobe.com/xap/1.0/sType/Dimensions#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceEvent#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceRef#",
    "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
    "http://purl.org/dc/elements/1.1/",
    "http://schemas.android.com/apk/res/android",
    "http://schemas.android.com/apk/res-auto",
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd",
    "https://www.openssl.org/docs/faq.html",
    "http://www.videolan.org/x264.html",
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
})
NATIVE_LIBRARY_METADATA_URLS = frozenset({
    "https://android.googlesource.com/toolchain/clang",
    "https://android.googlesource.com/toolchain/llvm",
    "https://android.googlesource.com/toolchain/llvm-project",
    "https://curl.haxx.se/docs/http-cookies.html",
    "https://www.openssl.org/docs/faq.html",
})
MP3_XMP_METADATA_URLS = frozenset({
    "http://ns.adobe.com/bwf/bext/1.0/",
    "http://ns.adobe.com/creatorAtom/1.0/",
    "http://ns.adobe.com/ixml/1.0/",
    "http://ns.adobe.com/xap/1.0/",
    "http://ns.adobe.com/xap/1.0/mm/",
    "http://ns.adobe.com/xap/1.0/sType/Dimensions#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceEvent#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceRef#",
    "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
    "http://purl.org/dc/elements/1.1/",
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
})
# ``2.1.0.0`` is the immutable KDJX app version, not an address. The other
# two literals are framework bind/broadcast sentinels and cannot route off
# device. Every other IPv4 literal in a client or hot-update artifact is a
# release failure unless it is the owned game host above.
KNOWN_NON_ENDPOINT_IP_LITERALS = frozenset({
    "0.0.0.0",
    "127.0.0.255",
    "2.1.0.0",
})
NATIVE_LIBRARY_METADATA_IP_LITERALS = frozenset({"1.0.0.0", "1.2.0.4", "127.0.0.1"})
URL_LITERAL_PATTERN = re.compile(
    r"https?://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:/[^\s\x00\"'<>\\]*)?",
    re.IGNORECASE,
)
IP_LITERAL_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_.-])",
)
PATCH_ASSET_NAME_PATTERN = re.compile(r"[A-Za-z0-9._@()/-]+")

LEGACY_NETWORK_REPLACEMENTS = {
    "http://oss.kuyangsh.cn/static/public/html/privacy_protection.html": "{origin}/games/kdjx/privacy",
    "http://service.tiancigame.cn/api/pingback/": "{origin}/games/kdjx/telemetry/",
    "https://ucenter.qingshangame.com/usercenter/v2/index.html#/home": "{origin}/games/kdjx/support",
    "http://dev.ucenter.tiancigame.cn/usercenter/v2/index.html#/home": "{origin}/games/kdjx/support",
    "https://cloud.xdrig.com/configcloud/rest/sdk/gdprCheck": "{origin}/games/kdjx/telemetry/talkingdata-gdpr",
    "https://cloud.xdrig.com/configcloud/rest/sdk/match": "{origin}/games/kdjx/telemetry/talkingdata-match",
    "http://android.bugly.qq.com/rqd/async": "{origin}/games/kdjx/telemetry/bugly-async",
    "http://rqd.uu.qq.com/rqd/sync": "{origin}/games/kdjx/telemetry/bugly-sync",
    "http://i.tddmp.com/a/": "{origin}/games/kdjx/telemetry/talkingdata",
    "http://dev.message.": "{origin}/games/kdjx/telemetry/",
    "https://message.": "{origin}/games/kdjx/telemetry/",
    "https://events.": "{origin}/games/kdjx/telemetry/",
    "https://service.": "{origin}/games/kdjx/telemetry/",
    "http://test.": "{origin}/games/kdjx/telemetry/",
    "mqqopensdkapi://bizAgent/qm/qr?url=http%3A%2F%2Fqm.qq.com%2Fcgi-bin%2Fqm%2Fqr%3Ffrom%3Dapp%26p%3Dandroid%26k%3D": "{origin}/games/kdjx/support",
    "https://adt.cpatrk.net": "{origin}/games/kdjx/telemetry/talkingdata-adt",
    "https://me.cpatrk.net": "{origin}/games/kdjx/telemetry/talkingdata-me",
    "heartbeat.qingshangame.com": OWNED_GAME_HOST,
    "adt.cpatrk.net": OWNED_GAME_HOST,
    "me.cpatrk.net": OWNED_GAME_HOST,
    "cloud.xdrig.com": OWNED_GAME_HOST,
    "www.talkingdata.net": OWNED_GAME_HOST,
    "bugly.qq.com": OWNED_GAME_HOST,
    "116.196.67.142": OWNED_GAME_HOST,
    "116.196.84.232": OWNED_GAME_HOST,
}

REQUIRED_GAME_SOURCE_FILES = (
    "app/sdk/helper.lua",
    "app/sdk/init.lua",
    "app/views/login/view.lua",
    "app/game_app.lua",
    "app/game_ui.lua",
    "app/defines/app_defines.lua",
)

# Fail closed for the first Sakura migration release. Later legacy patches can
# continue to use the generic builder, but patch 9 must always be reproducible
# from the audited production patch 8 snapshot.
FIRST_SAKURA_HOT_VERSION = "39"
FIRST_SAKURA_LOGIN_PATCH = "9"
FIRST_SAKURA_BOOTSTRAP_PATCH = "1"
FIRST_SAKURA_BASELINE_PATCH = 8
FIRST_SAKURA_APK_VERSION_CODE = 4
FIRST_SAKURA_BASELINE_ASSET_COUNT = 2553
FIRST_SAKURA_FINAL_ASSET_COUNT = 2559
FIRST_SAKURA_REPLACED_ASSETS = frozenset({
    "res/version.plist",
    "src/app.defines.app_defines",
    "src/app.game_app",
    "src/app.views.login.view",
    "x64/src/app.defines.app_defines",
    "x64/src/app.game_app",
    "x64/src/app.views.login.view",
})
FIRST_SAKURA_NEW_ASSETS = frozenset({
    "src/app.sdk.helper",
    "src/app.sdk.init",
    "src/app.sdk.none",
    "x64/src/app.sdk.helper",
    "x64/src/app.sdk.init",
    "x64/src/app.sdk.none",
})
FIRST_SAKURA_OWNED_ASSETS = (
    FIRST_SAKURA_REPLACED_ASSETS | FIRST_SAKURA_NEW_ASSETS
)


class BuildError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise BuildError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")


def copy_text(source: Path, destination: Path) -> str:
    text = source.read_text(encoding="utf-8")
    write_text(destination, text)
    return text


def owned_game_origin(value: str) -> str:
    parsed = urlparse(value.strip())
    if (
        parsed.scheme != "https"
        or parsed.hostname != OWNED_GAME_HOST
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        fail("game_origin_must_be_https_49_232_137_85")
    return f"https://{OWNED_GAME_HOST}"


def owned_api_origin(value: str) -> str:
    parsed = urlparse(value.strip().rstrip("/"))
    if (
        parsed.scheme != "https"
        or parsed.hostname != OWNED_GAME_HOST
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path != "/novel-api"
    ):
        fail("api_origin_must_be_https_49_232_137_85_novel_api")
    return DEFAULT_API_ORIGIN


def owned_download_base(value: str) -> str:
    parsed = urlparse(value.strip().rstrip("/"))
    if (
        parsed.scheme != "https"
        or parsed.hostname not in OWNED_DOWNLOAD_HOSTS
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path != "/games/kdjx/hot"
    ):
        fail("download_base_must_be_owned_games_kdjx_hot")
    return f"https://{parsed.hostname}/games/kdjx/hot"


def hot_version(value: str) -> str:
    if not re.fullmatch(r"[1-9][0-9]{0,8}", value):
        fail("hot_version_must_be_a_positive_integer")
    return value


def legacy_patch(value: str) -> str:
    if not re.fullmatch(r"[1-9][0-9]{0,8}", value):
        fail("login_patch_must_be_a_positive_integer")
    return value


def login_patch(value: str) -> str:
    return legacy_patch(value)


def source_apk_login_patch(apk: Path) -> str:
    if not apk.is_file() or apk.suffix.lower() != ".apk":
        fail("input_apk_missing")
    try:
        with zipfile.ZipFile(apk) as archive:
            payload = archive.read("assets/res/version.plist")
        values = plistlib.loads(payload)
    except (
        KeyError,
        OSError,
        plistlib.InvalidFileException,
        zipfile.BadZipFile,
    ) as error:
        fail(f"source_apk_version_plist_invalid:{error.__class__.__name__}")
    patch = values.get("patch")
    if not isinstance(patch, (str, int)) or isinstance(patch, bool):
        fail("source_apk_login_patch_invalid")
    return legacy_patch(str(patch))


def apk_version_code(value: str | None) -> int:
    if value is None or not re.fullmatch(r"[1-9][0-9]{0,9}", value):
        fail("apk_version_code_must_be_a_positive_integer")
    parsed = int(value)
    if parsed > MAX_ANDROID_VERSION_CODE:
        fail(f"apk_version_code_must_not_exceed_{MAX_ANDROID_VERSION_CODE}")
    return parsed


def requested_apk_version_code(value: str | None, skip_apk: bool) -> int | None:
    if skip_apk:
        if value is not None:
            fail("apk_version_code_not_allowed_with_skip_apk")
        return None
    if value is None:
        fail("apk_version_code_required")
    return apk_version_code(value)


def enforce_first_sakura_release_contract(
    version: str,
    target_patch: str,
    source_patch: str,
    upgrade_patches: object,
    baseline_asset_count: object,
    target_version_code: int | None,
) -> None:
    if target_patch != FIRST_SAKURA_LOGIN_PATCH:
        return
    if version != FIRST_SAKURA_HOT_VERSION:
        fail(f"first_sakura_hot_version_must_be_{FIRST_SAKURA_HOT_VERSION}")
    if source_patch != FIRST_SAKURA_BOOTSTRAP_PATCH:
        fail(
            "first_sakura_bootstrap_patch_must_be_"
            f"{FIRST_SAKURA_BOOTSTRAP_PATCH}"
        )
    if upgrade_patches != [FIRST_SAKURA_BASELINE_PATCH]:
        fail(
            "first_sakura_upgrade_path_must_be_"
            f"{FIRST_SAKURA_BASELINE_PATCH}"
        )
    if baseline_asset_count != FIRST_SAKURA_BASELINE_ASSET_COUNT:
        fail(
            "first_sakura_baseline_asset_count_must_be_"
            f"{FIRST_SAKURA_BASELINE_ASSET_COUNT}"
        )
    if (
        target_version_code is not None
        and target_version_code != FIRST_SAKURA_APK_VERSION_CODE
    ):
        fail(
            "first_sakura_apk_version_code_must_be_"
            f"{FIRST_SAKURA_APK_VERSION_CODE}"
        )


def enforce_first_sakura_asset_contract(
    target_patch: str,
    baseline_patch: int,
    baseline_names: Iterable[str],
    generated_names: Iterable[str],
) -> None:
    if target_patch != FIRST_SAKURA_LOGIN_PATCH:
        return
    baseline = set(baseline_names)
    generated = set(generated_names)
    if baseline_patch != FIRST_SAKURA_BASELINE_PATCH:
        fail(
            "first_sakura_baseline_patch_must_be_"
            f"{FIRST_SAKURA_BASELINE_PATCH}"
        )
    if len(baseline) != FIRST_SAKURA_BASELINE_ASSET_COUNT:
        fail(
            "first_sakura_baseline_name_count_must_be_"
            f"{FIRST_SAKURA_BASELINE_ASSET_COUNT}"
        )
    if generated != FIRST_SAKURA_OWNED_ASSETS:
        fail("first_sakura_owned_asset_set_mismatch")
    if baseline & generated != FIRST_SAKURA_REPLACED_ASSETS:
        fail("first_sakura_baseline_overlay_set_mismatch")
    if len(baseline | generated) != FIRST_SAKURA_FINAL_ASSET_COUNT:
        fail(
            "first_sakura_final_asset_count_must_be_"
            f"{FIRST_SAKURA_FINAL_ASSET_COUNT}"
        )


def replace_once(text: str, old: str, new: str, name: str) -> str:
    if text.count(old) != 1:
        fail(f"source_marker_not_unique:{name}")
    return text.replace(old, new, 1)


def replace_regex_once(text: str, pattern: str, replacement: str, name: str) -> str:
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        fail(f"source_marker_not_unique:{name}")
    return text


def replace_smali_method_once(
    text: str,
    declaration: str,
    replacement: str,
    name: str,
) -> str:
    pattern = (
        rf"^\.method {re.escape(declaration)}\n"
        r".*?"
        r"^\.end method$"
    )
    text, count = re.subn(
        pattern,
        replacement.rstrip("\n"),
        text,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    if count != 1:
        fail(f"source_marker_not_unique:{name}")
    return text


def patch_gl_surface_lifecycle_smali(text: str) -> str:
    if (
        "invoke-super {p0}, "
        "Landroid/opengl/GLSurfaceView;->onPause()V" in text
        or "Landroid/opengl/GLSurfaceView;->requestRender()V" in text
    ):
        fail("cocos_gl_surface_lifecycle_already_patched")
    text = replace_smali_method_once(
        text,
        "public onPause()V",
        """.method public onPause()V
    .locals 2

    sget-object v0, Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;->TAG:Ljava/lang/String;

    const-string v1, "onPause()"

    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    new-instance v0, Lorg/cocos2dx/lib/V;

    invoke-direct {v0, p0}, Lorg/cocos2dx/lib/V;-><init>(Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;)V

    invoke-virtual {p0, v0}, Landroid/opengl/GLSurfaceView;->queueEvent(Ljava/lang/Runnable;)V

    const/4 v0, 0x0

    invoke-virtual {p0, v0}, Landroid/opengl/GLSurfaceView;->setRenderMode(I)V

    invoke-super {p0}, Landroid/opengl/GLSurfaceView;->onPause()V

    return-void
.end method
""",
        "cocos_gl_surface_pause",
    )
    return replace_smali_method_once(
        text,
        "public onResume()V",
        """.method public onResume()V
    .locals 2

    sget-object v0, Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;->TAG:Ljava/lang/String;

    const-string v1, "onResume()"

    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    invoke-super {p0}, Landroid/opengl/GLSurfaceView;->onResume()V

    new-instance v0, Lorg/cocos2dx/lib/U;

    invoke-direct {v0, p0}, Lorg/cocos2dx/lib/U;-><init>(Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;)V

    invoke-virtual {p0, v0}, Landroid/opengl/GLSurfaceView;->queueEvent(Ljava/lang/Runnable;)V

    const/4 v0, 0x1

    invoke-virtual {p0, v0}, Landroid/opengl/GLSurfaceView;->setRenderMode(I)V

    invoke-virtual {p0}, Landroid/opengl/GLSurfaceView;->requestRender()V

    return-void
.end method
""",
        "cocos_gl_surface_resume",
    )


def patch_cocos_activity_lifecycle_smali(text: str) -> str:
    if ".field private engineResumed:Z" in text:
        fail("cocos_activity_lifecycle_already_patched")
    text = replace_once(
        text,
        ".field private gainAudioFocus:Z\n\n.field private hasFocus:Z",
        ".field private engineResumed:Z\n\n"
        ".field private gainAudioFocus:Z\n\n"
        ".field private hasFocus:Z",
        "cocos_activity_engine_resumed_field",
    )
    text = replace_smali_method_once(
        text,
        "private resumeIfHasFocus()V",
        """.method private resumeIfHasFocus()V
    .locals 1

    iget-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->paused:Z

    if-nez v0, :cond_return

    iget-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->hasFocus:Z

    if-eqz v0, :cond_return

    iget-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->engineResumed:Z

    if-nez v0, :cond_return

    invoke-static {}, Lorg/cocos2dx/lib/Cocos2dxActivity;->isDeviceLocked()Z

    move-result v0

    if-nez v0, :cond_return

    invoke-static {}, Lorg/cocos2dx/lib/Cocos2dxActivity;->isDeviceAsleep()Z

    move-result v0

    if-nez v0, :cond_return

    invoke-virtual {p0}, Lorg/cocos2dx/lib/Cocos2dxActivity;->hideVirtualButton()V

    const/4 v0, 0x1

    iput-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->engineResumed:Z

    invoke-static {}, Lorg/cocos2dx/lib/Cocos2dxHelper;->onResume()V

    iget-object v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->mGLSurfaceView:Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;

    invoke-virtual {v0}, Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;->onResume()V

    :cond_return
    return-void
.end method
""",
        "cocos_activity_resume_guard",
    )
    return replace_smali_method_once(
        text,
        "protected onPause()V",
        """.method protected onPause()V
    .locals 2

    sget-object v0, Lorg/cocos2dx/lib/Cocos2dxActivity;->TAG:Ljava/lang/String;

    const-string v1, "onPause()"

    invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    const/4 v0, 0x1

    iput-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->paused:Z

    const/4 v0, 0x0

    iput-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->engineResumed:Z

    invoke-super {p0}, Landroid/app/Activity;->onPause()V

    iget-boolean v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->gainAudioFocus:Z

    if-eqz v0, :cond_0

    invoke-static {p0}, Lorg/cocos2dx/lib/Cocos2dxAudioFocusManager;->b(Landroid/content/Context;)V

    :cond_0
    invoke-static {}, Lorg/cocos2dx/lib/Cocos2dxHelper;->onPause()V

    iget-object v0, p0, Lorg/cocos2dx/lib/Cocos2dxActivity;->mGLSurfaceView:Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;

    invoke-virtual {v0}, Lorg/cocos2dx/lib/Cocos2dxGLSurfaceView;->onPause()V

    return-void
.end method
""",
        "cocos_activity_pause_guard_reset",
    )


def patch_cocos_render_lifecycle(decoded: Path) -> None:
    classes = (
        "Cocos2dxGLSurfaceView.smali",
        "Cocos2dxActivity.smali",
    )
    located: dict[str, Path] = {}
    for class_name in classes:
        matches = list(
            decoded.glob(f"smali*/org/cocos2dx/lib/{class_name}")
        )
        if len(matches) != 1:
            fail(f"cocos_smali_not_unique:{class_name}")
        located[class_name] = matches[0]

    gl_surface = located["Cocos2dxGLSurfaceView.smali"]
    write_text(
        gl_surface,
        patch_gl_surface_lifecycle_smali(
            gl_surface.read_text(encoding="utf-8")
        ),
    )
    activity = located["Cocos2dxActivity.smali"]
    write_text(
        activity,
        patch_cocos_activity_lifecycle_smali(
            activity.read_text(encoding="utf-8")
        ),
    )


def sakura_none_lua() -> str:
    """No legacy web payment fallback is retained in the Sakura adapter."""
    return '''-- Sakura channel adapter. This module is loaded from channel=none once,
-- then makes the runtime channel explicit for login-server filtering.
local none = {}

local function decodeReply(value)
    if type(value) ~= "string" or value == "" or type(json) ~= "table"
            or type(json.decode) ~= "function" then
        return nil
    end
    local ok, decoded = pcall(json.decode, value)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

local function encodePayload(value)
    if type(json) ~= "table" or type(json.encode) ~= "function" then
        return nil
    end
    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == "string" then
        return encoded
    end
    return nil
end

local function platformCall(name, bundle, cb)
    if type(sdk) ~= "table" or type(sdk.callPlatformFunc) ~= "function" then
        return cb('{"status":"error","error":"sdk_bridge_unavailable"}')
    end
    return sdk.callPlatformFunc(name, bundle, cb)
end

local function identifier(value)
    return type(value) == "string" and value ~= "" and #value <= 128
        and string.match(value, "^[A-Za-z0-9%._:%-]+$") ~= nil
end

-- app.sdk.init selects this legacy module from channel.plist. Set the semantic
-- channel after module selection so the TCP login packet reaches Sakura SSO.
APP_CHANNEL = "sakura"
if type(dev) == "table" then
    dev.DEBUG_MODE = false
end

function none.getChannel(_)
    return "sakura"
end

function none.commitRoleInfo(_, cb)
    return cb()
end

function none.login(cb)
    platformCall("sakuraLogin", "{}", function(info)
        local response = decodeReply(info)
        local ticket = response and response.ticket or nil
        if response and response.status == "ok" and identifier(ticket)
                and string.sub(ticket, 1, 11) == "kdjx_login_" then
            return cb(0, ticket)
        end
        if printWarn then printWarn("Sakura login failed %s", tostring(info)) end
        return cb(-1, response and response.error or "sakura_login_failed")
    end)
end

function none.pay(cpOrderId, extInfo, amount, rechargeId, _, cb)
    local extra = decodeReply(extInfo)
    if type(extra) ~= "table" then
        return cb(-1, "invalid_payment_context")
    end
    local payload = {
        gameOrderId = tostring(cpOrderId or ""),
        productId = tostring(rechargeId or ""),
        accountId = tostring(extra[1] or ""),
        roleId = tostring(extra[2] or ""),
        serverKey = tostring(extra[3] or ""),
        yyId = tostring(extra[5] or ""),
        csvId = tostring(extra[6] or ""),
        -- This is informational only. Sakura charges by productId using its
        -- server catalog, so the existing yuan label is never rewritten.
        displayAmountYuan = tonumber(amount) or 0,
    }
    for _, value in pairs({
        payload.gameOrderId, payload.productId, payload.accountId,
        payload.roleId, payload.serverKey, payload.yyId, payload.csvId,
    }) do
        if not identifier(value) then
            return cb(-1, "invalid_payment_context")
        end
    end
    local encoded = encodePayload(payload)
    if not encoded then
        return cb(-1, "sdk_bridge_unavailable")
    end
    platformCall("sakuraPay", encoded, function(info)
        local response = decodeReply(info)
        if response and (response.status == "fulfilled"
                or response.status == "delivered" or response.status == "success") then
            return cb(0)
        end
        return cb(-1, response and response.status or "sakura_payment_failed")
    end)
end

function none.logout(cb)
    platformCall("sakuraClearSession", "{}", function()
        if cb then cb() end
    end)
end

return none
'''


def transform_helper(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    return replace_once(
        text,
        'luaj.callStaticMethod("org/cocos2dx/lua/MessageHandler", "msgFromLua", {',
        'luaj.callStaticMethod("www/tianji/finalsdk/MessageHandler", "msgFromLua", {',
        "message_handler_class",
    )


def transform_sdk_init(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    text = replace_regex_once(
        text,
        r"^sdk\.ORDER_URL\s*=.*$",
        "sdk.ORDER_URL = nil",
        "legacy_order_url",
    )
    text = replace_regex_once(
        text,
        r"^sdk\.ORDER_SIGN_SECRET\s*=.*$",
        "sdk.ORDER_SIGN_SECRET = nil",
        "legacy_order_secret",
    )
    return replace_regex_once(
        text,
        r"^\treturn sdk\.spec\.pay\(getCpOrderId\(\), extInfo, tonumber\(payInfo\.rmb\), rechargeId, params\.name or payInfo\.name, cb\)$",
        "\t-- The Sakura adapter preserves rechargeId and the visible yuan amount.\n"
        "\treturn sdk.spec.pay(getCpOrderId(), extInfo, tonumber(payInfo.rmb), rechargeId, params.name or payInfo.name, cb)",
        "sakura_payment_adapter",
    )


def transform_login_view(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "\tself.btnProtocol:hide()\n",
        "\tif self.btnProtocol then self.btnProtocol:hide() end\n"
        "\tif self.btnRegister then self.btnRegister:setVisible(false) end\n"
        "\tif self.btnReturn then self.btnReturn:setVisible(false) end\n"
        "\tself.btnLogin:get(\"login\"):setText(\"Sakura 登录\")\n",
        "sakura_login_button",
    )
    for button, expected_count in (
        ("btnRegister", 3),
        ("btnReturn", 4),
    ):
        pattern = rf"^(\s*)self\.{button}:setVisible\((true|false)\)$"
        text, count = re.subn(
            pattern,
            lambda match: (
                f"{match.group(1)}if self.{button} then "
                f"self.{button}:setVisible({match.group(2)}) end"
            ),
            text,
            flags=re.MULTILINE,
        )
        if count != expected_count:
            fail(f"source_marker_not_unique:optional_{button}:{count}")
    text = replace_once(
        text,
        "\t\t\t\t\tself:onServerLogin(info)",
        "\t\t\t\t\tself:onServerLogin(info, info)",
        "sakura_login_proof",
    )
    text = re.sub(
        r"^-- \[\{\"id\":1.*$",
        "-- Server addresses are supplied by the owned login service.",
        text,
        flags=re.MULTILINE,
    )
    return text


def transform_app_defines(source: Path, game_origin: str) -> str:
    text = source.read_text(encoding="utf-8")
    support = f'{game_origin}/games/kdjx/support'
    download = "https://novel.kxhub.xyz/games/kdjx/"
    text, support_count = re.subn(
        r'^(\s*)globals\.SUPPORT_URL\s*=.*$',
        lambda match: f'{match.group(1)}globals.SUPPORT_URL = "{support}"',
        text,
        flags=re.MULTILINE,
    )
    if support_count < 1:
        fail("source_marker_missing:support_url")
    text, shop_count = re.subn(
        r'^globals\.JUMP_SHOP_URL\s*=.*$',
        f'globals.JUMP_SHOP_URL = "{download}"',
        text,
        flags=re.MULTILINE,
    )
    if shop_count != 1:
        fail("source_marker_not_unique:jump_shop_url")
    text, discord_count = re.subn(
        r'^globals\.DISCORD_URL\s*=.*$',
        f'globals.DISCORD_URL = "{support}"',
        text,
        flags=re.MULTILINE,
    )
    if discord_count != 1:
        fail("source_marker_not_unique:discord_url")
    text = re.sub(
        r'^--\s*https?://.*$',
        "-- External reference removed from the release client.",
        text,
        flags=re.MULTILINE,
    )
    text = re.sub(
        r'^--\s*"https?://[^\"]+".*$',
        "-- Runtime endpoints are supplied by res/version.plist.",
        text,
        flags=re.MULTILINE,
    )
    text = re.sub(r'\s*--\s*or\s*"https?://[^\"]+"', "", text)
    return text


def transform_game_app(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "display.director:setDirtyDrawEnable(true)",
        "display.director:setDirtyDrawEnable(false)",
        "game_app_dirty_draw",
    )
    return replace_once(
        text,
        "function GameApp:onCreate()\n",
        """local function applyFullWidthBounds()
	if type(CC_DESIGN_RESOLUTION) ~= "table"
			or CC_DESIGN_RESOLUTION.autoscale ~= "FIXED_HEIGHT"
			or type(display) ~= "table"
			or display.uiOrigin == nil
			or display.uiOriginMax == nil
			or display.director == nil then
		return
	end

	local fullWidth = 1560 * 2
	local designHeight = CC_DESIGN_RESOLUTION.height
	local originX = (fullWidth - CC_DESIGN_RESOLUTION.width) / 2
	local view = display.director:getOpenGLView()
	if view == nil then
		return
	end

	view:setDesignResolutionSize(
		fullWidth,
		designHeight,
		cc.ResolutionPolicy.EXACT_FIT
	)
	-- The updater may leave its old wide-screen side boards attached to the
	-- director. They otherwise survive scene changes and cover the left edge.
	display.director:setNotificationNode(nil)
	CC_DESIGN_RESOLUTION.maxWidth = fullWidth
	display.sizeInView.width = fullWidth
	display.sizeInView.height = designHeight
	display.maxWidth = fullWidth
	display.uiOrigin.x = originX
	display.uiOriginMax.x = originX
	display.board_left = -originX
	display.board_right = CC_DESIGN_RESOLUTION.width + originX
	display.sizeInViewRect = cc.rect(
		0,
		0,
		fullWidth,
		designHeight
	)
end

function GameApp:onCreate()
	applyFullWidthBounds()
""",
        "game_app_full_width_bounds",
    )


def transform_game_ui(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    return replace_once(
        text,
        "if self.outSceneNode == nil and display.uiOrigin.x > display.uiOriginMax.x then",
        """local coverUnsupportedWideArea = false
	if coverUnsupportedWideArea
			and self.outSceneNode == nil
			and display.uiOrigin.x > display.uiOriginMax.x then""",
        "game_ui_wide_side_boards",
    )


def transform_framework_defines(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    return replace_once(
        text,
        "local maxWidth = 1560 * 2",
        "local maxWidth = 1600 * 2",
        "framework_max_width",
    )


def version_plist(game_origin: str, login_patch_value: str) -> bytes:
    login_patch_value = legacy_patch(login_patch_value)
    values = {
        "app_version": "2.1.0.0",
        "loginServer": f"{OWNED_GAME_HOST}:16666",
        # Keep the fallback on the same owned listener until the second TCP
        # listener is explicitly provisioned.
        "loginServer2": f"{OWNED_GAME_HOST}:16666",
        "patch": login_patch_value,
        "serverUrl": f"{game_origin}/kdjx/servers",
        "versionUrl": f"{game_origin}/kdjx/version",
        "noticeUrl": f"{game_origin}/kdjx/notice",
        "reportUrl": f"{game_origin}/kdjx/report",
        "disableWordCheckUrl": f"{game_origin}/kdjx/word-check",
        "feedBackUrl": f"{game_origin}/kdjx/feedback",
        "forShenhe": "false",
    }
    # XML plist parsers do not need the legacy Apple DTD. Omitting it ensures
    # the shipped hot update has no third-party URL even as metadata.
    return plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=False).replace(
        b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n',
        b"",
    )


def source_file(root: Path, relative: str) -> Path:
    path = root.joinpath(*relative.split("/"))
    if not path.is_file():
        fail(f"game_source_file_missing:{relative}")
    return path


def framework_source_file(application_root: Path, relative: str) -> Path:
    path = (
        application_root.parent.parent
        / "framework"
        / "MyLuaGame"
        / "src"
    ).joinpath(*relative.split("/"))
    if not path.is_file():
        fail(f"game_framework_source_file_missing:{relative}")
    return path


def safe_patch_asset_name(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and bool(PATCH_ASSET_NAME_PATTERN.fullmatch(value))
        and not value.startswith("/")
        and "\\" not in value
        and all(part not in ("", ".", "..") for part in value.split("/"))
    )


def resolve_game_source(path: Path) -> Path:
    """Accept application/src directly or a complete checked-out KDJX root."""
    root = path.resolve()
    candidates = (
        root,
        root / "application" / "src",
        root / "release" / "anti_cheat" / "game_scripts" / "application" / "src",
        root / "mnt" / "pokemon" / "release" / "anti_cheat" / "game_scripts" / "application" / "src",
    )
    for candidate in candidates:
        if candidate.is_dir() and all(
            candidate.joinpath(*relative.split("/")).is_file()
            for relative in REQUIRED_GAME_SOURCE_FILES
        ):
            return candidate
    fail("game_source_requires_full_application_src")


def build_hot_assets(
    source_root: Path,
    release_root: Path,
    game_origin: str,
    login_patch_value: str,
    baseline_catalog: Path,
    baseline_files_root: Path,
    baseline_patch: int,
) -> list[Path]:
    try:
        baseline_entries = json.loads(
            baseline_catalog.read_text(encoding="utf-8")
        )["files"]
    except (KeyError, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"server_patch_catalog_invalid:{baseline_patch}:{error.__class__.__name__}")
    if not isinstance(baseline_entries, list) or not baseline_entries:
        fail(f"server_patch_catalog_files_invalid:{baseline_patch}")

    baseline_names: list[str] = []
    baseline_name_set: set[str] = set()
    baseline_assets: list[tuple[str, Path]] = []
    for entry in baseline_entries:
        if not isinstance(entry, dict) or not safe_patch_asset_name(entry.get("name")):
            fail(f"server_patch_catalog_entry_invalid:{baseline_patch}")
        relative = entry["name"]
        if relative in baseline_name_set:
            fail(f"server_patch_catalog_name_invalid:{baseline_patch}")
        baseline_names.append(relative)
        baseline_name_set.add(relative)
        source = baseline_files_root / str(baseline_patch) / Path(relative)
        baseline_assets.append((relative, source))

    generated: dict[str, str | bytes] = {
        "src/app.sdk.none": sakura_none_lua(),
        "src/app.sdk.helper": transform_helper(source_file(source_root, "app/sdk/helper.lua")),
        "src/app.sdk.init": transform_sdk_init(source_file(source_root, "app/sdk/init.lua")),
        "src/app.views.login.view": transform_login_view(source_file(source_root, "app/views/login/view.lua")),
        "src/app.game_app": source_file(source_root, "app/game_app.lua").read_text(encoding="utf-8"),
        "src/app.defines.app_defines": transform_app_defines(
            source_file(source_root, "app/defines/app_defines.lua"), game_origin),
        "res/version.plist": version_plist(game_origin, login_patch_value),
    }
    if int(login_patch_value) > int(FIRST_SAKURA_LOGIN_PATCH):
        generated["src/app.game_app"] = transform_game_app(
            source_file(source_root, "app/game_app.lua")
        )
        generated["src/app.game_ui"] = transform_game_ui(
            source_file(source_root, "app/game_ui.lua")
        )
        generated["src/defines"] = transform_framework_defines(
            framework_source_file(source_root, "defines.lua")
        )
    # The legacy updater exposes architecture-specific Lua names as ordinary
    # catalog entries. Overlay both namespaces so x64 clients cannot retain
    # the historical login or payment implementation from patch 8.
    for relative, payload in list(generated.items()):
        if relative.startswith("src/"):
            generated[f"x64/{relative}"] = payload

    enforce_first_sakura_asset_contract(
        login_patch_value,
        baseline_patch,
        baseline_names,
        generated,
    )

    for relative, source in baseline_assets:
        destination = release_root.joinpath(*relative.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)

    for relative, payload in generated.items():
        destination = release_root.joinpath(*relative.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(payload, bytes):
            destination.write_bytes(payload)
        else:
            write_text(destination, payload)
    return sorted(
        (path for path in release_root.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(release_root).as_posix(),
    )


def build_hot_manifests(staging: Path, version: str, download_base: str, assets: Iterable[Path]) -> None:
    version = hot_version(version)
    release_root = staging / "releases" / version
    manifest_assets: dict[str, dict[str, object]] = {}
    total_bytes = 0
    for asset in sorted(
        assets,
        key=lambda path: path.relative_to(release_root).as_posix(),
    ):
        relative = asset.relative_to(release_root).as_posix()
        size = asset.stat().st_size
        total_bytes += size
        manifest_assets[relative] = {
            "size": size,
            "md5": md5(asset),
            "compressed": False,
        }
    base = f"{download_base}/"
    common = {
        "packageUrl": f"{base}releases/{version}/",
        "remoteVersionUrl": f"{base}version.manifest",
        "remoteManifestUrl": f"{base}project.manifest",
        "version": version,
    }
    project = {**common, "assets": manifest_assets, "searchPaths": []}
    version_manifest = dict(common)
    write_text(staging / "project.manifest", json.dumps(project, ensure_ascii=False, separators=(",", ":")))
    write_text(staging / "version.manifest", json.dumps(version_manifest, ensure_ascii=False, separators=(",", ":")))
    write_text(
        staging / "release-metadata.json",
        json.dumps(
            {"version": version, "assetCount": len(manifest_assets), "totalBytes": total_bytes},
            ensure_ascii=False,
            separators=(",", ":"),
        ),
    )


def build_legacy_patch(
    output: Path,
    staging: Path,
    release_root: Path,
    version: str,
    target_patch: str,
    assets: Iterable[Path],
) -> tuple[Path, int]:
    """Create the updater contract consumed by the production Go login service."""
    version = hot_version(version)
    target_patch = login_patch(target_patch)
    patch_root = staging / target_patch
    catalog_files: list[dict[str, object]] = []
    revision = hashlib.sha1()

    for asset in sorted(
        assets,
        key=lambda path: path.relative_to(release_root).as_posix(),
    ):
        relative = asset.relative_to(release_root).as_posix()
        if not safe_patch_asset_name(relative):
            fail(f"legacy_patch_asset_path_invalid:{relative}")
        destination = patch_root.joinpath(*relative.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(asset, destination)
        size = destination.stat().st_size
        digest = md5(destination)
        catalog_files.append({
            "name": relative,
            "size": size,
            "md5": digest,
            "patch": int(target_patch),
        })
        revision.update(f"{relative}\0{size}\0{digest}\n".encode("utf-8"))

    if not catalog_files:
        fail("legacy_patch_assets_missing")
    plist_entry = next(
        (entry for entry in catalog_files if entry["name"] == "res/version.plist"),
        None,
    )
    if plist_entry is None:
        fail("legacy_patch_version_plist_missing")
    plist_patch = str(
        plistlib.loads((patch_root / "res" / "version.plist").read_bytes())["patch"]
    )
    if plist_patch != target_patch:
        fail(f"legacy_patch_version_plist_mismatch:{plist_patch}")

    catalog_path = output / "login-patch" / "cn" / f"{target_patch}.json"
    catalog_text = json.dumps(
        {
            "files": catalog_files,
            "svn_version": version,
            "git_version": revision.hexdigest(),
        },
        ensure_ascii=False,
        indent=2,
    ) + "\n"
    write_text(catalog_path, catalog_text)
    write_text(
        staging / "legacy-patch.json",
        catalog_text,
    )
    verify_legacy_patch(catalog_path, patch_root, target_patch, version)
    verify_legacy_patch(
        staging / "legacy-patch.json",
        patch_root,
        target_patch,
        version,
    )
    return catalog_path, len(catalog_files)


def verify_legacy_patch(
    catalog_path: Path,
    patch_root: Path,
    expected_patch: str,
    expected_version: str,
) -> None:
    expected_patch = login_patch(expected_patch)
    expected_version = hot_version(expected_version)
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"legacy_patch_catalog_invalid:{error.__class__.__name__}")
    files = catalog.get("files")
    if not isinstance(files, list) or not files:
        fail("legacy_patch_catalog_files_invalid")
    if catalog.get("svn_version") != expected_version:
        fail("legacy_patch_catalog_version_mismatch")

    names: set[str] = set()
    previous_name = ""
    revision = hashlib.sha1()
    for entry in files:
        if not isinstance(entry, dict):
            fail("legacy_patch_catalog_entry_invalid")
        name = entry.get("name")
        if (
            not safe_patch_asset_name(name)
            or name in names
        ):
            fail("legacy_patch_catalog_name_invalid")
        if previous_name and name <= previous_name:
            fail("legacy_patch_catalog_order_invalid")
        previous_name = name
        names.add(name)
        path = patch_root.joinpath(*name.split("/"))
        if not path.is_file():
            fail(f"legacy_patch_asset_missing:{name}")
        if entry.get("patch") != int(expected_patch):
            fail(f"legacy_patch_number_mismatch:{name}")
        if entry.get("size") != path.stat().st_size or entry.get("md5") != md5(path):
            fail(f"legacy_patch_digest_mismatch:{name}")
        revision.update(
            f"{name}\0{entry['size']}\0{entry['md5']}\n".encode("utf-8")
        )

    if catalog.get("git_version") != revision.hexdigest():
        fail("legacy_patch_catalog_revision_mismatch")

    actual_names = {
        path.relative_to(patch_root).as_posix()
        for path in patch_root.rglob("*")
        if path.is_file()
    }
    if actual_names != names:
        fail("legacy_patch_file_set_mismatch")
    if "res/version.plist" not in names:
        fail("legacy_patch_version_plist_missing")


def audit_server_patch_baseline(
    catalog_dir: Path,
    files_dir: Path,
    source_patch: str,
    target_patch: str,
) -> dict[str, object]:
    """Prove the source APK can reach the new patch through retained history."""
    source_number = int(legacy_patch(source_patch))
    target_number = int(login_patch(target_patch))
    if target_number <= source_number:
        fail(f"login_patch_must_exceed_source_apk_patch_{source_number}")
    if not catalog_dir.is_dir() or catalog_dir.is_symlink():
        fail("server_patch_catalog_dir_invalid")
    if not files_dir.is_dir() or files_dir.is_symlink():
        fail("server_patch_files_dir_invalid")

    catalogs: dict[int, Path] = {}
    for path in catalog_dir.iterdir():
        if path.is_file() and not path.is_symlink() and re.fullmatch(r"[1-9][0-9]{0,8}\.json", path.name):
            catalogs[int(path.stem)] = path
    if not catalogs:
        fail("server_patch_catalogs_missing")
    if max(catalogs) >= target_number:
        fail(f"login_patch_must_exceed_server_patch_{max(catalogs)}")
    if target_number - 1 not in catalogs:
        fail(f"server_patch_predecessor_missing:{target_number - 1}")

    selected = sorted(
        patch for patch in catalogs
        if source_number < patch < target_number
    )
    if not selected:
        fail("server_patch_upgrade_path_missing")

    total_assets = 0
    total_bytes = 0
    for patch_number in selected:
        catalog_path = catalogs[patch_number]
        try:
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"server_patch_catalog_invalid:{patch_number}:{error.__class__.__name__}")
        entries = catalog.get("files")
        if not isinstance(entries, list) or not entries:
            fail(f"server_patch_catalog_files_invalid:{patch_number}")
        names: set[str] = set()
        has_version_plist = False
        for entry in entries:
            if not isinstance(entry, dict):
                fail(f"server_patch_catalog_entry_invalid:{patch_number}")
            name = entry.get("name")
            expected_size = entry.get("size")
            expected_md5 = entry.get("md5")
            if (
                not safe_patch_asset_name(name)
                or name in names
            ):
                fail(f"server_patch_catalog_name_invalid:{patch_number}")
            names.add(name)
            if (
                not isinstance(expected_size, int)
                or isinstance(expected_size, bool)
                or expected_size <= 0
                or not isinstance(expected_md5, str)
                or not re.fullmatch(r"[a-f0-9]{32}", expected_md5)
                or entry.get("patch") != patch_number
            ):
                fail(f"server_patch_catalog_metadata_invalid:{patch_number}:{name}")
            path = files_dir / str(patch_number) / Path(name)
            if not path.is_file() or path.is_symlink():
                fail(f"server_patch_asset_missing:{patch_number}:{name}")
            if path.stat().st_size != expected_size or md5(path) != expected_md5:
                fail(f"server_patch_asset_digest_mismatch:{patch_number}:{name}")
            total_assets += 1
            total_bytes += expected_size
            if name == "res/version.plist":
                has_version_plist = True
                try:
                    file_patch = str(plistlib.loads(path.read_bytes())["patch"])
                except (KeyError, plistlib.InvalidFileException):
                    fail(f"server_patch_version_plist_invalid:{patch_number}")
                if file_patch != str(patch_number):
                    fail(f"server_patch_version_plist_mismatch:{patch_number}")
        if not has_version_plist:
            fail(f"server_patch_version_plist_missing:{patch_number}")

    return {
        "sourceApkLoginPatch": str(source_number),
        "serverExistingPatches": sorted(catalogs),
        "serverUpgradePatches": selected,
        "serverBaselineAssetCount": total_assets,
        "serverBaselineBytes": total_bytes,
    }


def command_for(tool: Path, args: list[str]) -> list[str]:
    if os.name == "nt" and tool.suffix.lower() in {".cmd", ".bat"}:
        return ["cmd.exe", "/d", "/s", "/c", subprocess.list2cmdline([str(tool), *args])]
    return [str(tool), *args]


def run_tool(tool: Path, args: list[str], cwd: Path | None = None) -> None:
    completed = subprocess.run(
        command_for(tool, args),
        cwd=str(cwd) if cwd else None,
        stdout=sys.stdout,
        stderr=sys.stderr,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"tool_failed:{tool.name}")


def resolve_tool(candidate: str | None, names: tuple[str, ...], known: tuple[Path, ...]) -> Path:
    if candidate:
        path = Path(candidate)
        if path.is_file():
            return path.resolve()
        located = shutil.which(candidate)
        if located:
            return Path(located).resolve()
        fail(f"tool_not_found:{candidate}")
    for known_path in known:
        if known_path.is_file():
            return known_path.resolve()
    for name in names:
        located = shutil.which(name)
        if located:
            return Path(located).resolve()
    fail(f"tool_not_found:{names[0]}")


def find_android_jar(candidate: str | None) -> Path:
    if candidate:
        path = Path(candidate)
        if path.is_file():
            return path.resolve()
        fail("android_jar_not_found")
    sdk_root = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    candidates: list[Path] = []
    if sdk_root:
        candidates.extend(Path(sdk_root).glob("platforms/android-*/android.jar"))
    candidates.extend(Path(r"G:\Android\Sdk\platforms").glob("android-*/android.jar"))
    if not candidates:
        fail("android_jar_not_found")
    return max(candidates, key=lambda path: int(re.search(r"android-(\d+)", str(path.parent)).group(1)))


def write_compile_stubs(directory: Path) -> None:
    app_activity = directory / "org" / "cocos2dx" / "lua" / "AppActivity.java"
    call_info = directory / "www" / "tianji" / "finalsdk" / "CallInfo.java"
    handler = directory / "www" / "tianji" / "finalsdk" / "MessageHandler.java"
    write_text(
        app_activity,
        """package org.cocos2dx.lua;
public class AppActivity extends android.app.Activity {
  protected void onCreate(android.os.Bundle state) { super.onCreate(state); }
  protected void onNewIntent(android.content.Intent intent) { super.onNewIntent(intent); }
}
""",
    )
    write_text(
        call_info,
        """package www.tianji.finalsdk;
public class CallInfo { public int msgID; public String bundle; }
""",
    )
    write_text(
        handler,
        """package www.tianji.finalsdk;
public class MessageHandler { public void callbackToLua(int id, String value) {} }
""",
    )


def compile_bridge(work: Path, api_origin: str, android_jar: Path, d8: Path) -> Path:
    if not NATIVE_SOURCE.is_file() or not PAYMENT_RECOVERY_SOURCE.is_file():
        fail("native_bridge_source_missing")
    javac = resolve_tool(None, ("javac.exe", "javac"), ())
    source_root = work / "java-source"
    stub_source = source_root / "stubs"
    bridge_root = source_root / "bridge" / "com" / "novel" / "kdjx"
    bridge_source = bridge_root / "SakuraGameActivity.java"
    payment_recovery_source = bridge_root / "PaymentRecovery.java"
    write_compile_stubs(stub_source)
    bridge_text = NATIVE_SOURCE.read_text(encoding="utf-8")
    api_origin = owned_api_origin(api_origin)
    if bridge_text.count("__KDJX_API_ORIGIN__") != 1:
        fail("native_bridge_placeholder_invalid")
    write_text(bridge_source, bridge_text.replace("__KDJX_API_ORIGIN__", api_origin))
    payment_recovery_text = PAYMENT_RECOVERY_SOURCE.read_text(encoding="utf-8")
    if "__KDJX_API_ORIGIN__" in payment_recovery_text:
        fail("native_bridge_placeholder_invalid")
    write_text(payment_recovery_source, payment_recovery_text)

    stub_classes = work / "stub-classes"
    bridge_classes = work / "bridge-classes"
    stub_files = [str(path) for path in sorted(stub_source.rglob("*.java"))]
    run_tool(javac, ["-source", "8", "-target", "8", "-cp", str(android_jar), "-d", str(stub_classes), *stub_files])
    run_tool(
        javac,
        [
            "-source", "8", "-target", "8", "-cp", f"{android_jar}{os.pathsep}{stub_classes}",
            "-d", str(bridge_classes),
            str(bridge_source), str(payment_recovery_source),
        ],
    )
    dex_output = work / "dex"
    class_files = [str(path) for path in sorted(bridge_classes.rglob("*.class"))]
    if not class_files:
        fail("native_bridge_compile_empty")
    dex_output.mkdir(parents=True, exist_ok=False)
    run_tool(
        d8,
        [
            "--min-api", "16", "--lib", str(android_jar),
            "--classpath", str(stub_classes), "--output", str(dex_output),
            *class_files,
        ],
    )
    dex = dex_output / "classes.dex"
    if not dex.is_file():
        fail("native_bridge_dex_missing")
    return dex


def manifest_version_code(root: ET.Element) -> int | None:
    raw_value = root.get(ANDROID + "versionCode")
    if raw_value is None:
        return None
    if not re.fullmatch(r"[1-9][0-9]{0,9}", raw_value):
        fail("apk_manifest_version_code_invalid")
    parsed = int(raw_value)
    if parsed > MAX_ANDROID_VERSION_CODE:
        fail("apk_manifest_version_code_invalid")
    return parsed


def modify_manifest(
    path: Path,
    source_version_code: int,
    target_version_code: int,
) -> None:
    source_version_code = apk_version_code(str(source_version_code))
    target_version_code = apk_version_code(str(target_version_code))
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != "manifest":
        fail("apk_manifest_root_invalid")
    decoded_version_code = manifest_version_code(root)
    if (
        decoded_version_code is not None
        and decoded_version_code != source_version_code
    ):
        fail("apk_manifest_version_code_mismatch")
    if decoded_version_code is not None:
        root.set(ANDROID + "versionCode", str(target_version_code))

    app = root.find("application")
    if app is None:
        fail("apk_manifest_application_missing")
    app.set(ANDROID + "usesCleartextTraffic", "false")
    app.set(ANDROID + "allowBackup", "false")

    for child in list(app):
        if child.tag != "activity":
            continue
        for intent_filter in list(child.findall("intent-filter")):
            actions = {item.get(ANDROID + "name") for item in intent_filter.findall("action")}
            categories = {item.get(ANDROID + "name") for item in intent_filter.findall("category")}
            if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in categories:
                child.remove(intent_filter)

    bridge_name = "com.novel.kdjx.SakuraGameActivity"
    if any(item.get(ANDROID + "name") == bridge_name for item in app.findall("activity")):
        fail("apk_manifest_bridge_already_present")
    bridge = ET.Element("activity", {
        ANDROID + "name": bridge_name,
        ANDROID + "configChanges": "keyboardHidden|orientation|screenSize",
        ANDROID + "label": "@string/app_name",
        ANDROID + "launchMode": "singleTask",
        ANDROID + "maxAspectRatio": "3.0",
        ANDROID + "resizeableActivity": "true",
        ANDROID + "screenOrientation": "sensorLandscape",
        ANDROID + "theme": "@android:style/Theme.NoTitleBar.Fullscreen",
        ANDROID + "exported": "true",
    })
    intent_filter = ET.SubElement(bridge, "intent-filter")
    ET.SubElement(intent_filter, "action", {ANDROID + "name": "android.intent.action.MAIN"})
    ET.SubElement(intent_filter, "category", {ANDROID + "name": "android.intent.category.LAUNCHER"})
    app.insert(0, bridge)

    # Disable the bundled legacy telemetry SDKs. Their classes may remain in
    # the immutable upstream dex, but no component or configuration can start
    # them after the package is rebuilt.
    disabled_metadata = {
        "GG_TD_CONGIF", "GG_TD_TDID", "GG_TD_CHANNEL", "GG_BUGLY_CONGIF",
        "BUGLY_APPID", "BUGLY_APP_VERSION", "BUGLY_APP_CHANNEL", "BUGLY_ENABLE_DEBUG",
        "GG_XINGGE_CONGIF", "GG_OAID_CONGIF",
    }
    disabled_component_prefixes = (
        "com.talkingdata.",
        "com.tendcloud.",
        "com.tencent.bugly.",
    )
    for item in list(app):
        name = item.get(ANDROID + "name", "")
        if (
            item.tag == "meta-data" and name in disabled_metadata
        ) or name.startswith(disabled_component_prefixes):
            app.remove(item)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def modify_apktool_version(
    path: Path,
    target_version_code: int,
) -> int:
    target_version_code = apk_version_code(str(target_version_code))
    if not path.is_file():
        fail("apktool_metadata_missing")
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(
        r"^([ \t]*versionCode:[ \t]*)(['\"]?)([0-9]+)(['\"]?)([ \t]*(?:#.*)?)$",
        flags=re.MULTILINE,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        fail("apktool_version_code_not_unique")
    match = matches[0]
    if match.group(2) != match.group(4):
        fail("apktool_version_code_invalid")
    source_version_code = apk_version_code(match.group(3))
    if target_version_code <= source_version_code:
        fail(f"apk_version_code_must_increase_from_{source_version_code}")
    replacement = (
        f"{match.group(1)}{match.group(2)}{target_version_code}"
        f"{match.group(4)}{match.group(5)}"
    )
    write_text(path, text[:match.start()] + replacement + text[match.end():])
    return source_version_code


def verify_rebuilt_version_metadata(
    manifest_path: Path,
    metadata_path: Path,
    expected_version_code: int,
) -> None:
    expected_version_code = apk_version_code(str(expected_version_code))
    metadata_text = metadata_path.read_text(encoding="utf-8")
    metadata_matches = re.findall(
        r"^[ \t]*versionCode:[ \t]*['\"]?([0-9]+)['\"]?[ \t]*(?:#.*)?$",
        metadata_text,
        flags=re.MULTILINE,
    )
    if (
        len(metadata_matches) != 1
        or apk_version_code(metadata_matches[0]) != expected_version_code
    ):
        fail("rebuilt_apk_version_code_mismatch")
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    decoded_version_code = manifest_version_code(root)
    if (
        root.tag != "manifest"
        or (
            decoded_version_code is not None
            and decoded_version_code != expected_version_code
        )
    ):
        fail("rebuilt_apk_version_code_mismatch")


def sanitize_tivicloud_config(path: Path, game_origin: str) -> None:
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<TivicloudSDK>
  <RunConfig appId="kdjx-sakura" appKey="" appName="KDJX"
      channelId="sakura" platformId="0" checkVersion="false" debug="false"
      extraSDK="" screenOrientation="landscape" language="zh"
      hostAddress="{game_origin}" openPermission="false" />
</TivicloudSDK>
'''
    write_text(path, xml)


def patch_legacy_sdk_endpoints(decoded: Path, game_origin: str) -> None:
    replacements = {
        old: value.format(origin=game_origin)
        for old, value in LEGACY_NETWORK_REPLACEMENTS.items()
    }
    text_suffixes = {".smali", ".xml", ".lua", ".json", ".plist", ".txt"}
    for path in sorted(decoded.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in text_suffixes:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        patched = text
        # Full URLs must win over their bare host fragments.
        for old in sorted(replacements, key=len, reverse=True):
            patched = patched.replace(old, replacements[old])
        if patched != text:
            write_text(path, patched)


def remove_legacy_native_libraries(decoded: Path) -> None:
    # Bugly is disabled at both the manifest and Java configuration layers.
    # Removing its native crash reporter prevents a stale bundled library from
    # retaining, or ever reaching, the original Bugly endpoint.
    for library in decoded.glob("lib/**/libBugly.so"):
        library.unlink()


def append_bridge_dex(apk: Path, dex: Path) -> None:
    with zipfile.ZipFile(apk, "r") as archive:
        existing = [name for name in archive.namelist() if re.fullmatch(r"classes(?:[2-9][0-9]*)?\.dex", name)]
    if "classes2.dex" in existing:
        fail("apk_unexpected_multidex")
    with zipfile.ZipFile(apk, "a", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(dex, "classes2.dex")


def build_apk(
    apk: Path,
    output: Path,
    game_origin: str,
    api_origin: str,
    version_plist_bytes: bytes,
    target_version_code: int,
    apktool: Path,
    android_jar: Path,
    d8: Path,
) -> Path:
    if not apk.is_file() or apk.suffix.lower() != ".apk":
        fail("input_apk_missing")
    with tempfile.TemporaryDirectory(prefix="novel-kdjx-client-") as temporary:
        work = Path(temporary)
        decoded = work / "decoded"
        run_tool(apktool, ["d", "-f", "-o", str(decoded), str(apk)])
        source_version_code = modify_apktool_version(
            decoded / "apktool.yml",
            target_version_code,
        )
        modify_manifest(
            decoded / "AndroidManifest.xml",
            source_version_code,
            target_version_code,
        )
        version_path = decoded / "assets" / "res" / "version.plist"
        version_path.parent.mkdir(parents=True, exist_ok=True)
        version_path.write_bytes(version_plist_bytes)
        sanitize_tivicloud_config(decoded / "assets" / "TivicloudSDK.xml", game_origin)
        patch_legacy_sdk_endpoints(decoded, game_origin)
        patch_cocos_render_lifecycle(decoded)
        remove_legacy_native_libraries(decoded)
        bridge_dex = compile_bridge(work, api_origin, android_jar, d8)
        unsigned = work / "unsigned.apk"
        run_tool(apktool, ["b", str(decoded), "-o", str(unsigned)])
        append_bridge_dex(unsigned, bridge_dex)
        manifest_check = work / "rebuilt-manifest"
        run_tool(
            apktool,
            [
                "d", "--only-manifest", "-f",
                "-o", str(manifest_check), str(unsigned),
            ],
        )
        verify_rebuilt_version_metadata(
            manifest_check / "AndroidManifest.xml",
            manifest_check / "apktool.yml",
            target_version_code,
        )
        shutil.copyfile(unsigned, output)
    return output


def endpoint_literal_violations(data: str, entry_name: str = "") -> list[str]:
    """Return non-owned HTTP(S) hosts and routable IPv4 literals in data."""
    normalized = unquote(data.replace(r"\\/", "/"))
    violations: set[str] = set()
    for literal in URL_LITERAL_PATTERN.findall(normalized):
        try:
            host = (urlparse(literal).hostname or "").lower()
        except ValueError:
            host = "invalid"
        if not allowed_client_url_literal(literal, entry_name):
            violations.add(f"url:{host}")
    for literal in IP_LITERAL_PATTERN.findall(normalized):
        try:
            address = str(ipaddress.ip_address(literal))
        except ValueError:
            continue
        if (
            address != OWNED_GAME_HOST
            and address not in KNOWN_NON_ENDPOINT_IP_LITERALS
            and not (
                entry_name.endswith("libcocos2dlua.so")
                and address in NATIVE_LIBRARY_METADATA_IP_LITERALS
            )
        ):
            violations.add(f"ip:{address}")
    return sorted(violations)


def allowed_client_url_literal(literal: str, entry_name: str) -> bool:
    # Binary string tables frequently terminate a literal with NUL padding.
    # It is not part of the URL and must not turn a known metadata literal
    # into a broader allow-list match.
    clean_literal = literal.split("\x00", 1)[0].rstrip(".,;:)]}")
    try:
        parsed = urlparse(clean_literal)
        parsed_host = (parsed.hostname or "").lower()
        parsed_port = parsed.port
    except ValueError:
        return False
    if (
        parsed_host == OWNED_GAME_HOST
        and parsed.scheme == "https"
        and parsed_port in (None, 443)
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
        and (
            parsed.path in ("", "/")
            or parsed.path.startswith("/kdjx/")
            or parsed.path.startswith("/games/kdjx/")
            or parsed.path == "/novel-api"
            or parsed.path.startswith("/novel-api/games/kdjx/")
        )
    ):
        return True
    if (
        parsed_host in OWNED_DOWNLOAD_HOSTS
        and parsed.scheme == "https"
        and parsed_port in (None, 443)
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
        and parsed.path.startswith("/games/kdjx/")
    ):
        return True
    if clean_literal not in METADATA_URL_LITERALS:
        return False
    entry = entry_name.replace("\\", "/")
    if clean_literal.startswith("http://schemas.android.com/"):
        return entry == "classes.dex" or (
            entry.startswith("res/") and entry.endswith(".xml")
        )
    if clean_literal in NATIVE_LIBRARY_METADATA_URLS:
        return entry.startswith("lib/") and entry.endswith("/libcocos2dlua.so")
    if clean_literal in MP3_XMP_METADATA_URLS:
        return entry.startswith("assets/") and entry.endswith(".mp3")
    if clean_literal == "http://www.apple.com/DTDs/PropertyList-1.0.dtd":
        return (
            (entry.startswith("assets/") and entry.endswith(".plist"))
            or (entry.startswith("lib/") and entry.endswith("/libcocos2dlua.so"))
        )
    return (
        clean_literal == "http://www.videolan.org/x264.html" and
        entry.startswith("assets/") and entry.endswith(".mp4")
    )


def scan_text(path: Path) -> list[str]:
    try:
        data = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        data = path.read_bytes().decode("utf-8", errors="ignore")
    forbidden = [
        f"legacy:{needle}"
        for needle in FORBIDDEN_ENDPOINTS
        if needle.lower() in data.lower()
    ]
    return sorted({*forbidden, *endpoint_literal_violations(data)})


def zip_entry_violations(apk: Path) -> list[str]:
    violations: list[str] = []
    needles = {needle: needle.lower().encode("utf-8") for needle in FORBIDDEN_ENDPOINTS}
    tail_size = max(8192, max(len(needle) for needle in needles.values()) - 1)
    with zipfile.ZipFile(apk) as archive:
        for entry in archive.infolist():
            found: set[str] = set()
            tail = b""
            with archive.open(entry) as source:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    haystack = (tail + chunk).lower()
                    for label, needle in needles.items():
                        if needle in haystack:
                            found.add(f"legacy:{label}")
                    found.update(endpoint_literal_violations(
                        (tail + chunk).decode("latin-1"), entry.filename,
                    ))
                    tail = (tail + chunk)[-tail_size:]
            violations.extend(f"{entry.filename}:{needle}" for needle in sorted(found))
    return violations


def audit_outputs(output: Path, hot_staging: Path, apk: Path | None, download_base: str) -> dict[str, object]:
    violations: list[str] = []
    for path in sorted(hot_staging.rglob("*")):
        if path.is_file():
            for needle in scan_text(path):
                violations.append(f"{path.relative_to(output).as_posix()}:{needle}")
    if apk:
        violations.extend(zip_entry_violations(apk))
    if violations:
        fail("forbidden_runtime_endpoint:" + ",".join(violations))
    return {
        "ok": True,
        "ownedGameHost": OWNED_GAME_HOST,
        "hotUpdateBase": download_base,
        "allowedClientUrlHosts": sorted(OWNED_CLIENT_URL_HOSTS),
        "metadataUrlLiterals": sorted(METADATA_URL_LITERALS),
        "forbiddenRuntimeEndpoints": list(FORBIDDEN_ENDPOINTS),
        "apkSha256": sha256(apk) if apk else None,
    }


def prepare_output(path: Path, force: bool) -> None:
    if path.exists():
        marker = path / ".kdjx-client-output"
        if not force:
            fail("output_exists_use_force")
        if not marker.is_file():
            fail("refusing_to_remove_unmarked_output")
        shutil.rmtree(path)
    path.mkdir(parents=True)
    write_text(path / ".kdjx-client-output", "generated by build_kdjx_client.py\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True, help="Original KDJX APK; never modified in place")
    parser.add_argument(
        "--game-source",
        type=Path,
        required=True,
        help="KDJX source root or prepared source directory",
    )
    parser.add_argument("--output", type=Path, required=True, help="New, dedicated output directory")
    parser.add_argument(
        "--server-patch-catalog-dir",
        type=Path,
        required=True,
        help="Retained Go login patch catalog directory, such as patch/cn",
    )
    parser.add_argument(
        "--server-patch-files-dir",
        type=Path,
        required=True,
        help="Retained legacy download tree containing numbered patch directories",
    )
    parser.add_argument(
        "--hot-version",
        required=True,
        help="Compatibility Cocos manifest version; independent from the legacy updater patch",
    )
    parser.add_argument(
        "--login-patch",
        required=True,
        help="Target legacy updater patch; the bootstrap APK embeds its predecessor",
    )
    parser.add_argument(
        "--apk-version-code",
        help="New Android versionCode; required for APK builds and must increase",
    )
    parser.add_argument("--game-origin", default=DEFAULT_GAME_ORIGIN)
    parser.add_argument("--download-base", default=DEFAULT_DOWNLOAD_BASE)
    parser.add_argument("--apktool", help="Path to apktool executable/cmd")
    parser.add_argument("--android-jar", help="Path to an Android platform android.jar")
    parser.add_argument("--d8", help="Path to Android d8 executable/cmd")
    parser.add_argument("--skip-apk", action="store_true", help="Only create and audit hot-update staging")
    parser.add_argument("--force", action="store_true", help="Replace an output directory created by this script")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        game_origin = owned_game_origin(args.game_origin)
        api_origin = owned_api_origin(DEFAULT_API_ORIGIN)
        download_base = owned_download_base(args.download_base)
        version = hot_version(args.hot_version)
        login_patch_value = login_patch(args.login_patch)
        source_apk_patch = source_apk_login_patch(args.apk.resolve())
        baseline_report = audit_server_patch_baseline(
            args.server_patch_catalog_dir.resolve(),
            args.server_patch_files_dir.resolve(),
            source_apk_patch,
            login_patch_value,
        )
        baseline_patch = int(baseline_report["serverUpgradePatches"][-1])
        target_apk_version_code = requested_apk_version_code(
            args.apk_version_code,
            args.skip_apk,
        )
        enforce_first_sakura_release_contract(
            version,
            login_patch_value,
            source_apk_patch,
            baseline_report["serverUpgradePatches"],
            baseline_report["serverBaselineAssetCount"],
            target_apk_version_code,
        )
        source_root = resolve_game_source(args.game_source)
        output = args.output.resolve()
        prepare_output(output, args.force)

        hot_staging = output / "hot-staging"
        release_root = hot_staging / "releases" / version
        assets = build_hot_assets(
            source_root,
            release_root,
            game_origin,
            login_patch_value,
            args.server_patch_catalog_dir.resolve() / f"{baseline_patch}.json",
            args.server_patch_files_dir.resolve(),
            baseline_patch,
        )
        build_hot_manifests(hot_staging, version, download_base, assets)
        legacy_catalog, legacy_asset_count = build_legacy_patch(
            output,
            hot_staging,
            release_root,
            version,
            login_patch_value,
            assets,
        )

        patched_apk: Path | None = None
        if not args.skip_apk:
            apktool = resolve_tool(
                args.apktool,
                ("apktool.cmd", "apktool"),
                (Path(r"E:\tools\apk-reverse\bin\apktool.cmd"),),
            )
            android_jar = find_android_jar(args.android_jar)
            d8 = resolve_tool(
                args.d8,
                ("d8.bat", "d8"),
                (Path(r"G:\Android\Sdk\cmdline-tools\latest\bin\d8.bat"),),
            )
            patched_apk = output / "kdjx-sakura-unsigned.apk"
            build_apk(
                args.apk.resolve(),
                patched_apk,
                game_origin,
                api_origin,
                version_plist(game_origin, source_apk_patch),
                target_apk_version_code,
                apktool,
                android_jar,
                d8,
            )

        report = audit_outputs(output, hot_staging, patched_apk, download_base)
        report.update({
            "hotVersion": version,
            "loginPatch": login_patch_value,
            "bootstrapLoginPatch": source_apk_patch,
            "legacyPatchMode": "cumulative",
            "legacyCatalog": legacy_catalog.relative_to(output).as_posix(),
            "legacyAssetCount": legacy_asset_count,
            "apkVersionCode": target_apk_version_code,
            "gameOrigin": game_origin,
            "apiOrigin": api_origin,
            "downloadBase": download_base,
            "generatedAt": int(time.time()),
            "unsignedApk": patched_apk.name if patched_apk else None,
        })
        report.update(baseline_report)
        write_text(output / "verification.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(report, ensure_ascii=False))
        return 0
    except BuildError as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
