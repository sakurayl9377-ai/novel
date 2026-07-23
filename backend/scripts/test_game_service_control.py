#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "game-service-control.py"
INSTALLER_PATH = SCRIPT_DIR / "install-game-service-control.sh"
DEPLOY_PATH = SCRIPT_DIR / "deploy-production.sh"
SPEC = importlib.util.spec_from_file_location("game_service_control", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GameServiceControlTest(unittest.TestCase):
    def test_service_groups_are_fixed(self):
        self.assertEqual(
            MODULE.SERVICE_GROUPS,
            {
                "bailian": (
                    "bailian-game.service",
                    "bailian-backstage.service",
                ),
                "modao": (
                    "modao-redis.service",
                    "modao-static.service",
                    "modao-account.service",
                    "modao-game.service",
                ),
            },
        )
        self.assertEqual(
            MODULE.ALLOWED_ACTIONS,
            {"status", "start", "stop", "restart"},
        )

    def test_stop_uses_fixed_reverse_order_and_reports_stopped(self):
        calls = []

        def fake_systemctl(args, timeout=90):
            calls.append((list(args), timeout))
            if args[0] == "disable":
                return subprocess.CompletedProcess(args, 0, "", "")
            unit = args[1]
            output = "\n".join(
                [
                    "LoadState=loaded",
                    "ActiveState=inactive",
                    "SubState=dead",
                    "UnitFileState=disabled",
                ]
            )
            return subprocess.CompletedProcess([unit], 0, output, "")

        output = io.StringIO()
        with mock.patch.object(MODULE, "systemctl", side_effect=fake_systemctl):
            with contextlib.redirect_stdout(output):
                MODULE.run_action(
                    "bailian",
                    "stop",
                    MODULE.SERVICE_GROUPS["bailian"],
                )

        self.assertEqual(
            calls[0][0],
            [
                "disable",
                "--now",
                "bailian-backstage.service",
                "bailian-game.service",
            ],
        )
        response = json.loads(output.getvalue())
        self.assertTrue(response["ok"])
        self.assertEqual(response["data"]["gameId"], "bailian")
        self.assertTrue(
            all(unit["status"] == "stopped" for unit in response["data"]["units"])
        )
        self.assertTrue(
            all(not unit["enabled"] for unit in response["data"]["units"])
        )

    def test_main_rejects_unknown_game_before_systemctl(self):
        output = io.StringIO()
        with mock.patch.object(MODULE.os, "geteuid", return_value=0, create=True):
            with mock.patch.object(
                MODULE.sys,
                "argv",
                ["game-service-control.py", "modao;id", "start"],
            ):
                with mock.patch.object(MODULE, "systemctl") as systemctl_mock:
                    with contextlib.redirect_stdout(output):
                        with self.assertRaises(SystemExit):
                            MODULE.main()
        systemctl_mock.assert_not_called()
        self.assertEqual(
            json.loads(output.getvalue())["error"],
            "game_control_game_invalid",
        )

    def test_main_rejects_unknown_action_before_systemctl(self):
        output = io.StringIO()
        with mock.patch.object(MODULE.os, "geteuid", return_value=0, create=True):
            with mock.patch.object(
                MODULE.sys,
                "argv",
                ["game-service-control.py", "modao", "restart;id"],
            ):
                with mock.patch.object(MODULE, "systemctl") as systemctl_mock:
                    with contextlib.redirect_stdout(output):
                        with self.assertRaises(SystemExit):
                            MODULE.main()
        systemctl_mock.assert_not_called()
        self.assertEqual(
            json.loads(output.getvalue())["error"],
            "game_control_action_invalid",
        )

    def test_non_root_execution_is_rejected(self):
        output = io.StringIO()
        with mock.patch.object(
            MODULE.os,
            "geteuid",
            return_value=1000,
            create=True,
        ):
            with mock.patch.object(MODULE, "systemctl") as systemctl_mock:
                with contextlib.redirect_stdout(output):
                    with self.assertRaises(SystemExit):
                        MODULE.main()
        systemctl_mock.assert_not_called()
        self.assertEqual(
            json.loads(output.getvalue())["error"],
            "game_control_not_root",
        )


class GameServiceDeploymentContractTest(unittest.TestCase):
    def test_installer_rolls_back_until_both_groups_pass_status(self):
        script = INSTALLER_PATH.read_text(encoding="utf-8")

        self.assertIn(
            '[[ "$sudoers_target" == '
            '"/etc/sudoers.d/${app_user}-novel-game-service-control" ]]',
            script,
        )
        self.assertIn("restore_installation()", script)
        self.assertIn("trap on_exit EXIT", script)
        self.assertIn('[[ "$install_started" == true ]]', script)
        self.assertIn('[[ "$committed" != true ]]', script)
        self.assertIn(
            'sudo -u "$app_user" sudo -n "$helper_target" modao status',
            script,
        )
        self.assertIn(
            'sudo -u "$app_user" sudo -n "$helper_target" bailian status',
            script,
        )

        backup = script.index(
            'cp -a -- "$helper_target" "$helper_backup"',
        )
        install_started = script.index("install_started=true")
        helper_move = script.index('mv -Tf "$helper_tmp" "$helper_target"')
        modao_check = script.index(
            'sudo -u "$app_user" sudo -n "$helper_target" modao status',
        )
        bailian_check = script.index(
            'sudo -u "$app_user" sudo -n "$helper_target" bailian status',
        )
        committed = script.index("committed=true", bailian_check)
        self.assertLess(backup, install_started)
        self.assertLess(install_started, helper_move)
        self.assertLess(helper_move, modao_check)
        self.assertLess(modao_check, bailian_check)
        self.assertLess(bailian_check, committed)

    def test_production_deploy_backs_up_installs_and_restores_control_files(self):
        script = DEPLOY_PATH.read_text(encoding="utf-8")

        self.assertIn(
            'game_helper_target="/usr/local/sbin/novel-game-service-control"',
            script,
        )
        self.assertIn(
            'game_sudoers_path="/etc/sudoers.d/'
            '${app_user}-novel-game-service-control"',
            script,
        )
        self.assertIn(
            '[[ -f "$new_release/scripts/game-service-control.py" ]]',
            script,
        )
        self.assertIn(
            '[[ -f "$new_release/scripts/install-game-service-control.sh" ]]',
            script,
        )
        self.assertIn(
            'install -o root -g root -m 0755 "$game_helper_backup" '
            '"$game_helper_restore"',
            script,
        )
        self.assertIn(
            'install -o root -g root -m 0440 "$game_sudoers_backup" '
            '"$game_sudoers_restore"',
            script,
        )
        self.assertIn(
            'rm -f "$game_helper_target" || restore_status=1',
            script,
        )
        self.assertIn(
            'rm -f "$game_sudoers_path" || restore_status=1',
            script,
        )

        helper_backup = script.index(
            'cp -a "$game_helper_target" "$game_helper_backup"',
        )
        sudoers_backup = script.index(
            'cp -a "$game_sudoers_path" "$game_sudoers_backup"',
        )
        installer = script.index(
            '/bin/bash "$new_release/scripts/install-game-service-control.sh"',
        )
        release_switch = script.index('ln -s "$new_release" "${app_link}.next"')
        self.assertLess(helper_backup, installer)
        self.assertLess(sudoers_backup, installer)
        self.assertLess(installer, release_switch)


if __name__ == "__main__":
    unittest.main()
