import subprocess
import tempfile
import unittest
from pathlib import Path

import build_kdjx_client as builder


class KdjxNativeAuthorizationContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = builder.NATIVE_SOURCE.read_text(encoding="utf-8")

    def test_user_code_is_server_bound_before_sakura_is_opened(self) -> None:
        self.assertIn('body.optString("userCode", "")', self.source)
        self.assertIn(
            "userCode.equals(normalizeUserCode(",
            self.source,
        )
        self.assertIn('uri.getQueryParameter("user_code")', self.source)
        self.assertLess(
            self.source.index("!isAuthorizationUri("),
            self.source.index("launchSakuraAuthorization("),
        )

    def test_game_confirmation_precedes_the_explicit_sakura_launch(self) -> None:
        self.assertIn(r'"\u53e3\u888b\u89c9\u9192 Sakura "', self.source)
        self.assertIn(r'"\u7801\uff1a\n\n" + userCode', self.source)
        self.assertIn('.setPositiveButton(', self.source)
        self.assertIn(r'"\u6253\u5f00 Sakura"', self.source)
        self.assertIn('.setNegativeButton(', self.source)
        self.assertIn(r'"\u53d6\u6d88"', self.source)
        self.assertIn('"authorization_cancelled"', self.source)
        dialog_index = self.source.index("new AlertDialog.Builder")
        launch_index = self.source.index("startActivity(intent)", dialog_index)
        self.assertLess(
            dialog_index,
            launch_index,
        )
        self.assertLess(
            self.source.index('.putString("device_code", deviceCode)'),
            launch_index,
        )

    def test_return_status_ends_denied_and_cancelled_without_polling(self) -> None:
        self.assertIn('"sakura_authorization_status"', self.source)
        self.assertIn('"approved".equals(authorizationStatus)', self.source)
        self.assertIn('"denied".equals(authorizationStatus)', self.source)
        self.assertIn('"cancelled".equals(authorizationStatus)', self.source)
        self.assertIn('"authorization_denied"', self.source)
        self.assertIn('"authorization_cancelled"', self.source)

    def test_vault_credential_is_exchanged_for_a_one_time_login_ticket(self) -> None:
        self.assertIn(
            'API_ORIGIN + "/games/kdjx/sessions/login-ticket"',
            self.source,
        )
        self.assertIn('"sakura_expected_user_id"', self.source)
        self.assertIn('payload.put("credential", credential)', self.source)
        self.assertIn('response.body.optBoolean("ok", false)', self.source)
        self.assertIn('response.body.optString("ticket", "")', self.source)
        self.assertIn('response.body.optInt("ticketExpiresIn", 0) != 60', self.source)
        self.assertIn('response.body.optString("userId", "")', self.source)
        self.assertIn(
            "!requiredUserId.equals(credentialUserId)",
            self.source,
        )
        self.assertIn("if (response.status == 401)", self.source)
        self.assertIn("SessionVault.clear(SakuraGameActivity.this)", self.source)
        self.assertIn('"login_ticket_unavailable"', self.source)
        self.assertIn('value.startsWith("kdjx_login_")', self.source)
        self.assertIn('result.put("ticket", ticket)', self.source)
        self.assertNotIn('result.put("credential"', self.source)
        self.assertNotIn('loginReply("ok", credential', self.source)
        self.assertIn("connection.setInstanceFollowRedirects(false)", self.source)

    def test_login_is_single_flight_and_keeps_its_expected_user_snapshot(self) -> None:
        self.assertIn("synchronized (loginLock)", self.source)
        self.assertIn("if (pendingLogin != null)", self.source)
        self.assertIn('loginReply("error", "", "login_in_progress")', self.source)
        self.assertIn(
            "new PendingLogin(callInfo, expectedUserId)",
            self.source,
        )
        self.assertIn("String requiredUserId = request.requiredUserId", self.source)
        self.assertNotIn("String requiredUserId = expectedUserId", self.source)
        self.assertGreaterEqual(
            self.source.count("if (!isPendingLogin(request)) return;"),
            6,
        )
        self.assertLess(
            self.source.index("if (pendingLogin != null)"),
            self.source.index("beginDeviceAuthorization(request)"),
        )

    def test_destroyed_activity_cancels_and_rejects_delayed_polling(self) -> None:
        self.assertIn("destroyed = true", self.source)
        self.assertIn("main.removeCallbacksAndMessages(null)", self.source)
        self.assertIn("if (destroyed || pendingLogin != request) return", self.source)
        self.assertIn("catch (RejectedExecutionException ignored)", self.source)
        self.assertIn("if (destroyed) return", self.source)
        self.assertLess(
            self.source.index("destroyed = true"),
            self.source.index("io.shutdownNow()"),
        )

    def test_fullscreen_layout_is_configured_before_cocos_creates_its_surface(
        self,
    ) -> None:
        create_start = self.source.index(
            "protected void onCreate(Bundle savedInstanceState)"
        )
        create_end = self.source.index(
            "public void onWindowFocusChanged",
            create_start,
        )
        create_source = self.source[create_start:create_end]
        self.assertLess(
            create_source.index("configureGameWindowLayout();"),
            create_source.index("super.onCreate(savedInstanceState);"),
        )
        self.assertIn("hideSystemBars();", create_source)
        self.assertEqual(
            1,
            self.source.count("configureGameWindowLayout();"),
        )
        self.assertNotIn("protected void onResume()", self.source)
        self.assertIn(
            "LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS",
            self.source,
        )
        self.assertIn(
            "LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES",
            self.source,
        )
        self.assertIn("window.setDecorFitsSystemWindows(false)", self.source)
        self.assertIn("WindowInsets.Type.systemBars()", self.source)

    def test_payment_pending_is_single_flight_and_expires_after_fifteen_minutes(self) -> None:
        self.assertIn(
            "MAX_PAYMENT_WAIT_MS = 15L * 60L * 1000L",
            self.source,
        )
        self.assertIn("synchronized (paymentLock)", self.source)
        self.assertIn('paymentReply("payment_in_progress")', self.source)
        self.assertIn(
            "stored != null && !orderId.equals(stored.orderId)",
            self.source,
        )
        self.assertIn("stored.returnNonce", self.source)
        self.assertIn("deadline - capturedAt == MAX_PAYMENT_WAIT_MS", self.source)
        self.assertIn("clearStoredPayment(null)", self.source)
        self.assertIn('paymentReply("payment_expired")', self.source)
        self.assertIn('.putLong("payment_deadline", payment.deadline)', self.source)
        expiry_index = self.source.index(
            "if (active != null && !active.isActive(now))"
        )
        rejection_index = self.source.index(
            "if (active != null)",
            expiry_index + 1,
        )
        replacement_index = self.source.index(
            "PendingPayment stored = readStoredPayment(now)",
            rejection_index,
        )
        self.assertLess(expiry_index, rejection_index)
        self.assertLess(rejection_index, replacement_index)

    def test_processing_payment_status_round_trips_to_lua(self) -> None:
        recovery_source = builder.PAYMENT_RECOVERY_SOURCE.read_text(
            encoding="utf-8"
        )
        self.assertIn('"processing".equals(value)', recovery_source)

    def test_terminal_payment_survives_activity_recreation(self) -> None:
        runner = """package com.novel.kdjx;
public final class PaymentRecoveryContract {
  private static void equal(String expected, String actual) {
    if (!expected.equals(actual)) throw new AssertionError(actual);
  }
  public static void main(String[] args) {
    String nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    long capturedAt = 1_000L;
    long deadline = capturedAt + 900_000L;
    equal("delivered", PaymentRecovery.returnedStatus(
        "order-1", nonce, capturedAt, deadline,
        "order-1", nonce, "delivered", 2_000L, 900_000L));
    equal("processing", PaymentRecovery.returnedStatus(
        "order-1", nonce, capturedAt, deadline,
        "order-1", nonce, "processing", 2_000L, 900_000L));
    equal("cancelled", PaymentRecovery.returnedStatus(
        "order-1", nonce, capturedAt, deadline,
        "order-1", nonce, "unknown", 2_000L, 900_000L));
    equal("", PaymentRecovery.returnedStatus(
        "order-1", nonce, capturedAt, deadline,
        "order-1", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "delivered", 2_000L, 900_000L));
    equal("", PaymentRecovery.returnedStatus(
        "order-1", nonce, capturedAt, deadline,
        "order-1", nonce, "delivered", deadline, 900_000L));
    System.out.print("payment-recovery-ok");
  }
}
"""
        javac = builder.resolve_tool(None, ("javac.exe", "javac"), ())
        java = builder.resolve_tool(None, ("java.exe", "java"), ())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "com" / "novel" / "kdjx"
            package.mkdir(parents=True)
            recovery = package / "PaymentRecovery.java"
            recovery.write_text(
                builder.PAYMENT_RECOVERY_SOURCE.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            contract = package / "PaymentRecoveryContract.java"
            contract.write_text(runner, encoding="utf-8")
            compiled = subprocess.run(
                builder.command_for(
                    javac,
                    ["-source", "8", "-target", "8", "-d", str(root),
                     str(recovery), str(contract)],
                ),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stderr)
            executed = subprocess.run(
                builder.command_for(
                    java,
                    ["-cp", str(root),
                     "com.novel.kdjx.PaymentRecoveryContract"],
                ),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, executed.returncode, executed.stderr)
            self.assertEqual("payment-recovery-ok", executed.stdout)



if __name__ == "__main__":
    unittest.main()
