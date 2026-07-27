import json
import tempfile
import unittest
from pathlib import Path

import build_kdjx_client as builder
import prepare_kdjx_client_source as preparer


class KdjxClientSourcePreparationTest(unittest.TestCase):
    def create_source(self, root: Path) -> Path:
        application = root / "application" / "src"
        for index, relative in enumerate(preparer.APPLICATION_FILES):
            source = application.joinpath(*relative.split("/"))
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(f"application fixture {index}\n", encoding="utf-8")
        framework = root / "framework" / "MyLuaGame" / "src" / "defines.lua"
        framework.parent.mkdir(parents=True, exist_ok=True)
        framework.write_text("local maxWidth = 1560 * 2\n", encoding="utf-8")
        return application

    def test_prepared_source_preserves_application_and_framework_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            game_scripts = root / "game_scripts"
            application = self.create_source(game_scripts)
            output = root / "prepared"

            self.assertEqual(application.resolve(), preparer.find_source(game_scripts))
            preparer.prepare(application, output, force=False)

            expected = [
                f"application/src/{relative}"
                for relative in preparer.APPLICATION_FILES
            ] + [
                f"framework/MyLuaGame/src/{relative}"
                for relative in preparer.FRAMEWORK_FILES
            ]
            manifest = json.loads(
                (output / "source-manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(expected, [entry["path"] for entry in manifest["files"]])
            for entry in manifest["files"]:
                prepared = output.joinpath(*entry["path"].split("/"))
                self.assertTrue(prepared.is_file())
                self.assertEqual(entry["sha256"], preparer.sha256(prepared))

            resolved = builder.resolve_game_source(output)
            self.assertEqual((output / "application" / "src").resolve(), resolved)
            self.assertEqual(
                (
                    output
                    / "framework"
                    / "MyLuaGame"
                    / "src"
                    / "defines.lua"
                ).resolve(),
                builder.framework_source_file(resolved, "defines.lua").resolve(),
            )

    def test_missing_framework_source_fails_before_output_is_created(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            game_scripts = root / "game_scripts"
            application = self.create_source(game_scripts)
            preparer.framework_source(application, "defines.lua").unlink()
            output = root / "prepared"

            with self.assertRaisesRegex(
                ValueError,
                "full_application_src_not_found",
            ):
                preparer.find_source(game_scripts)
            with self.assertRaisesRegex(
                ValueError,
                "full_application_src_not_found",
            ):
                preparer.prepare(application, output, force=False)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
