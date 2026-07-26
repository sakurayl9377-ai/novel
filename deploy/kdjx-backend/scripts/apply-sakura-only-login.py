#!/usr/bin/env python3
"""Apply fail-closed Sakura channel and one-time login-ticket gates."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


GATE = """\tif t.Channel != \"sakura\" {\n\t\treturn &taskCheckResponse{\n\t\t\tRet: false,\n\t\t\tErr: \"sakura_auth_required\",\n\t\t}\n\t}\n\n"""
MARKER = "\tlog.Infof(\"login channel `%s` tag `%s` guarder `%s`\", t.Channel, t.Tag, t.Guarder)\n\n"
OLD_PROOF_PREFIX = 'if !strings.HasPrefix(proof, "kdjx_session_") {'
LOGIN_PROOF_PREFIX = 'if !strings.HasPrefix(proof, "kdjx_login_") {'
OLD_VERIFY_PAYLOAD = 'json.Marshal(map[string]string{"credential": proof})'
LOGIN_VERIFY_PAYLOAD = 'json.Marshal(map[string]string{"ticket": proof})'
VERIFY_PATH = 'c.BaseURL+"/games/kdjx/sessions/verify"'
SESSION_REJECTION_TEST = r'''

func TestVerifyRejectsLongLivedSessionCredential(t *testing.T) {
	client := &Client{BaseURL: "https://example.invalid", SharedSecret: "secret"}
	proof := "kdjx_session_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
	if _, err := client.Verify(proof, proof); err == nil {
		t.Fatal("expected long-lived session credential to be rejected")
	}
}
'''


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def patch_channel_gate(path):
    content = path.read_text(encoding="utf-8")
    if 'if t.Channel != "sakura" {' not in content:
        if content.count(MARKER) != 1:
            fail("KDJX login task source does not match the supported source layout")
        content = content.replace(MARKER, MARKER + GATE, 1)
        path.write_text(content, encoding="utf-8")
    if content.count('if t.Channel != "sakura" {') != 1:
        fail("KDJX Sakura-only channel gate is incomplete")


def patch_login_verifier(path):
    content = path.read_text(encoding="utf-8")
    if OLD_PROOF_PREFIX in content:
        if content.count(OLD_PROOF_PREFIX) != 1:
            fail("KDJX verifier proof prefix is ambiguous")
        content = content.replace(OLD_PROOF_PREFIX, LOGIN_PROOF_PREFIX, 1)
    if OLD_VERIFY_PAYLOAD in content:
        if content.count(OLD_VERIFY_PAYLOAD) != 1:
            fail("KDJX verifier payload is ambiguous")
        content = content.replace(OLD_VERIFY_PAYLOAD, LOGIN_VERIFY_PAYLOAD, 1)
    if (
        content.count(LOGIN_PROOF_PREFIX) != 1
        or content.count(LOGIN_VERIFY_PAYLOAD) != 1
        or content.count(VERIFY_PATH) != 1
        or "kdjx_session_" in content
        or OLD_VERIFY_PAYLOAD in content
    ):
        fail("KDJX login verifier does not enforce one-time tickets")
    path.write_text(content, encoding="utf-8")


def patch_login_verifier_tests(path):
    if not path.is_file():
        return
    content = path.read_text(encoding="utf-8")
    rejection_start = content.find(
        "func TestVerifyRejectsLongLivedSessionCredential",
    )
    if rejection_start >= 0:
        rejection_end = content.find("\n}\n", rejection_start)
        if rejection_end < 0:
            fail("KDJX long-lived credential rejection test is malformed")
        content = (
            content[:rejection_start].rstrip()
            + "\n"
            + content[rejection_end + 3:].lstrip()
        )
    content = content.replace("TestVerifyCredential", "TestVerifyLoginTicket")
    content = content.replace("kdjx_session_", "kdjx_login_")
    content = content.replace('body["credential"]', 'body["ticket"]')
    content = content.replace(
        't.Fatal("credential was not forwarded")',
        't.Fatal("login ticket was not forwarded")',
    )
    content = content.rstrip() + "\n" + SESSION_REJECTION_TEST.lstrip()
    if (
        'body["credential"]' in content
        or "TestVerifyRejectsLongLivedSessionCredential" not in content
        or 'proof := "kdjx_session_' not in content
    ):
        fail("KDJX login verifier tests are incomplete")
    path.write_text(content, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    login_root = root / "gosrc" / "tjgame" / "login"
    task_path = login_root / "checkin" / "task" / "check.go"
    verifier_path = login_root / "sakuraauth" / "client.go"
    if not task_path.is_file():
        fail("KDJX login task source is missing: {}".format(task_path))
    if not verifier_path.is_file():
        fail("KDJX Sakura verifier source is missing: {}".format(verifier_path))

    patch_channel_gate(task_path)
    patch_login_verifier(verifier_path)
    patch_login_verifier_tests(verifier_path.with_name("client_test.go"))


if __name__ == "__main__":
    main()
