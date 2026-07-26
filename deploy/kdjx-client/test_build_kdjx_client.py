import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import build_kdjx_client as builder


class KdjxClientVersionContractTest(unittest.TestCase):
    def test_native_api_origin_is_path_scoped_to_the_owned_backend(self) -> None:
        self.assertEqual(
            "https://49.232.137.85/novel-api",
            builder.owned_api_origin(builder.DEFAULT_API_ORIGIN),
        )
        self.assertEqual(
            [],
            builder.endpoint_literal_violations(
                builder.DEFAULT_API_ORIGIN
                + "\x00@"
                + builder.DEFAULT_API_ORIGIN
                + "/games/kdjx/device-authorizations"
                + "\x00F"
                + builder.DEFAULT_API_ORIGIN
                + "/games/kdjx/device-authorizations/token"
                + "\x00:",
                "classes2.dex",
            ),
        )
        self.assertEqual(
            ["url:49.232.137.85"],
            builder.endpoint_literal_violations(
                builder.DEFAULT_API_ORIGIN + "/admin/users",
                "classes2.dex",
            ),
        )
        for invalid in (
            builder.DEFAULT_GAME_ORIGIN,
            "https://49.232.137.85/api",
            "https://novel.kxhub.xyz/novel-api",
            "http://49.232.137.85/novel-api",
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(builder.BuildError):
                    builder.owned_api_origin(invalid)

    def test_bootstrap_and_legacy_hot_patch_are_separate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            staging = output / "hot-staging"
            release_root = staging / "releases" / "39"
            generated = {
                "src/app.sdk.none": b"none",
                "src/app.sdk.helper": b"helper",
                "src/app.sdk.init": b"init",
                "src/app.views.login.view": b"login",
                "src/app.game_app": b"game",
                "src/app.defines.app_defines": b"defines",
                "res/Zeta.bin": b"uppercase path fixture",
                "res/alpha.bin": b"lowercase path fixture",
                "res/version.plist": builder.version_plist(
                    builder.DEFAULT_GAME_ORIGIN,
                    "9",
                ),
            }
            assets = []
            for relative, payload in generated.items():
                asset = release_root.joinpath(*relative.split("/"))
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_bytes(payload)
                assets.append(asset)

            builder.build_hot_manifests(
                staging,
                "39",
                builder.DEFAULT_DOWNLOAD_BASE,
                assets,
            )
            catalog_path, asset_count = builder.build_legacy_patch(
                output,
                staging,
                release_root,
                "39",
                "9",
                assets,
            )

            project = json.loads(
                (staging / "project.manifest").read_text(encoding="utf-8")
            )
            version = json.loads(
                (staging / "version.manifest").read_text(encoding="utf-8")
            )
            self.assertEqual("39", project["version"])
            self.assertEqual("39", version["version"])
            self.assertTrue(project["packageUrl"].endswith("/releases/39/"))
            self.assertEqual(len(generated), asset_count)

            bootstrap_plist = plistlib.loads(
                builder.version_plist(
                    builder.DEFAULT_GAME_ORIGIN,
                    "1",
                )
            )
            hot_plist = plistlib.loads(
                (staging / "9" / "res" / "version.plist").read_bytes()
            )
            self.assertEqual("1", bootstrap_plist["patch"])
            self.assertEqual("9", hot_plist["patch"])
            self.assertNotEqual(
                builder.version_plist(builder.DEFAULT_GAME_ORIGIN, "1"),
                (staging / "9" / "res" / "version.plist").read_bytes(),
            )

            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
            self.assertEqual("39", catalog["svn_version"])
            self.assertRegex(catalog["git_version"], r"^[a-f0-9]{40}$")
            self.assertEqual(set(generated), {
                entry["name"] for entry in catalog["files"]
            })
            self.assertEqual(
                sorted(entry["name"] for entry in catalog["files"]),
                [entry["name"] for entry in catalog["files"]],
            )
            for entry in catalog["files"]:
                self.assertEqual(9, entry["patch"])
                path = staging / "9" / Path(entry["name"])
                self.assertEqual(entry["size"], path.stat().st_size)
                self.assertEqual(entry["md5"], builder.md5(path))

            catalog["git_version"] = "0" * 40
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            with self.assertRaisesRegex(
                builder.BuildError,
                "legacy_patch_catalog_revision_mismatch",
            ):
                builder.verify_legacy_patch(
                    catalog_path,
                    staging / "9",
                    "9",
                    "39",
                )

            source_apk = output / "source.apk"
            with zipfile.ZipFile(source_apk, "w") as archive:
                archive.writestr(
                    "assets/res/version.plist",
                    builder.version_plist(builder.DEFAULT_GAME_ORIGIN, "1"),
                )
            self.assertEqual("1", builder.source_apk_login_patch(source_apk))

            catalog_dir = output / "server-catalogs"
            files_dir = output / "server-files"
            baseline_plist = files_dir / "8" / "res" / "version.plist"
            baseline_plist.parent.mkdir(parents=True)
            baseline_plist.write_bytes(
                builder.version_plist(builder.DEFAULT_GAME_ORIGIN, "8")
            )
            catalog_dir.mkdir()
            (catalog_dir / "8.json").write_text(
                json.dumps({
                    "files": [{
                        "name": "res/version.plist",
                        "size": baseline_plist.stat().st_size,
                        "md5": builder.md5(baseline_plist),
                        "patch": 8,
                    }],
                    "svn_version": "8",
                    "git_version": "0" * 40,
                }),
                encoding="utf-8",
            )
            baseline = builder.audit_server_patch_baseline(
                catalog_dir,
                files_dir,
                "1",
                "9",
            )
            self.assertEqual("1", baseline["sourceApkLoginPatch"])
            self.assertEqual([8], baseline["serverExistingPatches"])
            self.assertEqual([8], baseline["serverUpgradePatches"])
            self.assertEqual(1, baseline["serverBaselineAssetCount"])

        self.assertEqual("9", builder.login_patch("9"))
        self.assertEqual("10", builder.login_patch("10"))
        for invalid in ("0", "01", ""):
            with self.subTest(invalid=invalid):
                with self.assertRaises(builder.BuildError):
                    builder.login_patch(invalid)

    def test_first_sakura_release_is_bound_to_the_audited_cumulative_set(
        self,
    ) -> None:
        baseline = set(builder.FIRST_SAKURA_REPLACED_ASSETS)
        baseline.update(
            f"assets/cumulative/{index:04d}.bin"
            for index in range(
                builder.FIRST_SAKURA_BASELINE_ASSET_COUNT - len(baseline)
            )
        )
        builder.enforce_first_sakura_release_contract(
            "39",
            "9",
            "1",
            [8],
            2553,
            4,
        )
        builder.enforce_first_sakura_release_contract(
            "39",
            "9",
            "1",
            [8],
            2553,
            None,
        )
        builder.enforce_first_sakura_asset_contract(
            "9",
            8,
            baseline,
            builder.FIRST_SAKURA_OWNED_ASSETS,
        )
        self.assertEqual(
            2559,
            len(baseline | builder.FIRST_SAKURA_OWNED_ASSETS),
        )

        invalid_contracts = (
            ("38", "9", "1", [8], 2553, 4),
            ("39", "9", "8", [8], 2553, 4),
            ("39", "9", "1", [7, 8], 2553, 4),
            ("39", "9", "1", [8], 2552, 4),
            ("39", "9", "1", [8], 2553, 5),
        )
        for contract in invalid_contracts:
            with self.subTest(contract=contract):
                with self.assertRaises(builder.BuildError):
                    builder.enforce_first_sakura_release_contract(*contract)

        with self.assertRaisesRegex(
            builder.BuildError,
            "first_sakura_baseline_overlay_set_mismatch",
        ):
            builder.enforce_first_sakura_asset_contract(
                "9",
                8,
                baseline - {"res/version.plist"} | {"assets/replacement.bin"},
                builder.FIRST_SAKURA_OWNED_ASSETS,
            )

    def test_apk_version_code_argument_is_fail_closed(self) -> None:
        self.assertEqual(4, builder.apk_version_code("4"))
        self.assertEqual(
            builder.MAX_ANDROID_VERSION_CODE,
            builder.apk_version_code(str(builder.MAX_ANDROID_VERSION_CODE)),
        )
        self.assertEqual(4, builder.requested_apk_version_code("4", False))
        self.assertIsNone(builder.requested_apk_version_code(None, True))

        for invalid in (
            None,
            "",
            "0",
            "-1",
            "04",
            "4.0",
            " 4",
            str(builder.MAX_ANDROID_VERSION_CODE + 1),
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(builder.BuildError):
                    builder.apk_version_code(invalid)

        with self.assertRaisesRegex(builder.BuildError, "apk_version_code_required"):
            builder.requested_apk_version_code(None, False)
        with self.assertRaisesRegex(
            builder.BuildError,
            "apk_version_code_not_allowed_with_skip_apk",
        ):
            builder.requested_apk_version_code("4", True)

    def test_patch_asset_names_match_the_public_nginx_route(self) -> None:
        for valid in (
            "res/version.plist",
            "src/app.sdk.none",
            "assets/effect/sparkle@(2).png",
        ):
            with self.subTest(valid=valid):
                self.assertTrue(builder.safe_patch_asset_name(valid))

        for invalid in (
            "",
            "/res/version.plist",
            "res//version.plist",
            "res/./version.plist",
            "res/../version.plist",
            r"res\version.plist",
            "assets/name with spaces.png",
            "assets/query?.png",
        ):
            with self.subTest(invalid=invalid):
                self.assertFalse(builder.safe_patch_asset_name(invalid))

    def test_login_overlay_uses_the_requested_sakura_label(self) -> None:
        source_text = (
            "\tself.btnProtocol:hide()\n"
            "\t\t\t\t\tself:onServerLogin(info)\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "view.lua"
            source.write_text(source_text, encoding="utf-8")
            transformed = builder.transform_login_view(source)
        self.assertIn("Sakura \u767b\u5f55", transformed)

    def test_lua_login_accepts_only_the_native_one_time_ticket(self) -> None:
        adapter = builder.sakura_none_lua()
        self.assertIn("response.ticket", adapter)
        self.assertIn('string.sub(ticket, 1, 11) == "kdjx_login_"', adapter)
        self.assertNotIn("response.credential", adapter)
        self.assertNotIn("kdjx_session_", adapter)

    def test_manifest_and_apktool_metadata_bump_from_three_to_four(self) -> None:
        manifest = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.kdjx" android:versionCode="3" android:versionName="2.1.0.0">
  <application>
    <activity android:name="com.example.LegacyActivity">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
    </activity>
  </application>
</manifest>
"""
        apktool_metadata = """version: 3.0.0
apkFileName: kdjx.apk
versionInfo:
  versionCode: '3'
  versionName: 2.1.0.0
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "AndroidManifest.xml"
            metadata_path = root / "apktool.yml"
            manifest_path.write_text(manifest, encoding="utf-8")
            metadata_path.write_text(apktool_metadata, encoding="utf-8")

            with self.assertRaisesRegex(
                builder.BuildError,
                "apk_version_code_must_increase_from_3",
            ):
                builder.modify_apktool_version(metadata_path, 3)

            source_version_code = builder.modify_apktool_version(
                metadata_path,
                4,
            )
            builder.modify_manifest(manifest_path, source_version_code, 4)
            builder.verify_rebuilt_version_metadata(
                manifest_path,
                metadata_path,
                4,
            )

            root_element = ET.parse(manifest_path).getroot()
            self.assertEqual(
                "4",
                root_element.get(builder.ANDROID + "versionCode"),
            )
            self.assertIn("versionCode: '4'", metadata_path.read_text("utf-8"))

    def test_apktool_only_version_code_matches_real_apktool_three_output(
        self,
    ) -> None:
        manifest = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.kdjx">
  <application>
    <activity android:name="com.example.LegacyActivity" />
  </application>
</manifest>
"""
        metadata = """version: 3.0.2
apkFileName: kdjx.apk
versionInfo:
  versionCode: 3
  versionName: 2.1.0.0
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "AndroidManifest.xml"
            metadata_path = root / "apktool.yml"
            manifest_path.write_text(manifest, encoding="utf-8")
            metadata_path.write_text(metadata, encoding="utf-8")

            source_version_code = builder.modify_apktool_version(
                metadata_path,
                4,
            )
            self.assertEqual(3, source_version_code)
            builder.modify_manifest(manifest_path, source_version_code, 4)
            builder.verify_rebuilt_version_metadata(
                manifest_path,
                metadata_path,
                4,
            )
            self.assertIsNone(
                ET.parse(manifest_path)
                .getroot()
                .get(builder.ANDROID + "versionCode")
            )
            self.assertIn("versionCode: 4", metadata_path.read_text("utf-8"))


if __name__ == "__main__":
    unittest.main()
