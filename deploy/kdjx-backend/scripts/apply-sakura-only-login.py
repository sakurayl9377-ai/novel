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
STRICT_PROOF = """\tproof := strings.TrimSpace(clientName)
\tif proof == "" || proof != strings.TrimSpace(clientPass) {
\t\treturn nil, errors.New("sakura proof mismatch")
\t}
"""
COMPATIBLE_PROOF = """\tnameProof := strings.TrimSpace(clientName)
\tpassProof := strings.TrimSpace(clientPass)
\tnameIsTicket := strings.HasPrefix(nameProof, "kdjx_login_")
\tpassIsTicket := strings.HasPrefix(passProof, "kdjx_login_")
\tproof := ""
\tswitch {
\tcase nameIsTicket && passIsTicket && nameProof == passProof:
\t\tproof = nameProof
\tcase nameIsTicket && !passIsTicket:
\t\tproof = nameProof
\tcase passIsTicket && !nameIsTicket:
\t\tproof = passProof
\tdefault:
\t\treturn nil, errors.New("sakura proof mismatch")
\t}
"""
COMPATIBILITY_TEST_MARKER = "// kdjx-login-field-compatibility-tests-v1"
SESSION_REJECTION_TEST = r'''func TestVerifyRejectsLongLivedSessionCredential(t *testing.T) {
	client := &Client{BaseURL: "https://example.invalid", SharedSecret: "secret"}
	proof := "kdjx_session_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
	if _, err := client.Verify(proof, proof); err == nil {
		t.Fatal("expected long-lived session credential to be rejected")
	}
}
'''
COMPATIBILITY_TESTS = r'''

// kdjx-login-field-compatibility-tests-v1
func TestVerifyAcceptsLoginTicketInEitherLegacyField(t *testing.T) {
	proof := "kdjx_login_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
	tests := []struct {
		name       string
		clientName string
		clientPass string
	}{
		{name: "name field", clientName: proof, clientPass: "legacy-pass"},
		{name: "password field", clientName: "legacy-name", clientPass: proof},
		{name: "both fields", clientName: proof, clientPass: proof},
	}

	for _, testCase := range tests {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			requests := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests++
				var body map[string]string
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if body["ticket"] != proof {
					t.Fatalf("login ticket was not forwarded: %#v", body)
				}
				if _, exists := body["credential"]; exists {
					t.Fatal("long-lived credential field was forwarded")
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"accountName":"sakura_account","accountPassword":"compat-pass","channel":"sakura"}`))
			}))
			defer server.Close()

			client := &Client{
				BaseURL:      server.URL,
				SharedSecret: "shared-secret",
				HTTPClient:   server.Client(),
			}
			identity, err := client.Verify(testCase.clientName, testCase.clientPass)
			if err != nil {
				t.Fatal(err)
			}
			if requests != 1 {
				t.Fatalf("unexpected verifier request count: %d", requests)
			}
			if identity.AccountName != "sakura_account" || identity.AccountPassword != "compat-pass" {
				t.Fatalf("unexpected identity: %#v", identity)
			}
		})
	}
}
''' + "\n" + SESSION_REJECTION_TEST


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
    if STRICT_PROOF in content:
        if content.count(STRICT_PROOF) != 1:
            fail("KDJX verifier proof selection is ambiguous")
        content = content.replace(STRICT_PROOF, COMPATIBLE_PROOF, 1)
    if OLD_PROOF_PREFIX in content:
        if content.count(OLD_PROOF_PREFIX) != 1:
            fail("KDJX verifier proof prefix is ambiguous")
        content = content.replace(OLD_PROOF_PREFIX, LOGIN_PROOF_PREFIX, 1)
    if OLD_VERIFY_PAYLOAD in content:
        if content.count(OLD_VERIFY_PAYLOAD) != 1:
            fail("KDJX verifier payload is ambiguous")
        content = content.replace(OLD_VERIFY_PAYLOAD, LOGIN_VERIFY_PAYLOAD, 1)
    if (
        content.count(COMPATIBLE_PROOF) != 1
        or content.count(LOGIN_PROOF_PREFIX) != 1
        or content.count(LOGIN_VERIFY_PAYLOAD) != 1
        or content.count(VERIFY_PATH) != 1
        or "kdjx_session_" in content
        or OLD_VERIFY_PAYLOAD in content
        or STRICT_PROOF in content
    ):
        fail("KDJX login verifier does not enforce one-time tickets")
    path.write_text(content, encoding="utf-8")


def patch_login_verifier_tests(path):
    if not path.is_file():
        return
    content = path.read_text(encoding="utf-8")
    if COMPATIBILITY_TEST_MARKER not in content:
        session_test_name = "func TestVerifyRejectsLongLivedSessionCredential("
        if content.count(session_test_name) > 1:
            fail("KDJX long-lived credential rejection tests are ambiguous")
        if session_test_name in content:
            legacy_login_variant = SESSION_REJECTION_TEST.replace(
                "kdjx_session_",
                "kdjx_login_",
            )
            for previous_test in (
                SESSION_REJECTION_TEST,
                legacy_login_variant,
            ):
                if previous_test in content:
                    content = content.replace(previous_test, "", 1)
                    break
            if session_test_name in content:
                fail("KDJX long-lived credential rejection test is unsupported")
        content = content.replace("TestVerifyCredential", "TestVerifyLoginTicket")
        content = content.replace("kdjx_session_", "kdjx_login_")
        content = content.replace(
            'map[string]string{"credential": proof}',
            'map[string]string{"ticket": proof}',
        )
        content = content.replace('body["credential"]', 'body["ticket"]')
        content = content.replace(
            't.Fatal("credential was not forwarded")',
            't.Fatal("login ticket was not forwarded")',
        )
        if "TestVerifyRejectsMismatchedProof" in content:
            mismatched_call = (
                'client.Verify("kdjx_login_'
                'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", "different")'
            )
            conflicting_call = (
                'client.Verify("kdjx_login_'
                'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", '
                '"kdjx_login_ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210zyxwvut")'
            )
            if content.count(mismatched_call) != 1:
                fail("KDJX mismatched-proof test does not match the supported layout")
            content = content.replace(
                "TestVerifyRejectsMismatchedProof",
                "TestVerifyRejectsConflictingLoginTickets",
                1,
            )
            content = content.replace(mismatched_call, conflicting_call, 1)
        content = content.rstrip() + "\n" + COMPATIBILITY_TESTS.lstrip()
    if (
        content.count('body["credential"]') != 1
        or 'map[string]string{"credential": proof}' in content
        or content.count(COMPATIBILITY_TEST_MARKER) != 1
        or content.count(
            "func TestVerifyAcceptsLoginTicketInEitherLegacyField(",
        ) != 1
        or content.count("func TestVerifyRejectsConflictingLoginTickets(") != 1
        or content.count(
            "func TestVerifyRejectsLongLivedSessionCredential(",
        ) != 1
        or 'proof := "kdjx_session_' not in content
        or 'clientName: proof, clientPass: "legacy-pass"' not in content
        or 'clientName: "legacy-name", clientPass: proof' not in content
        or "clientName: proof, clientPass: proof" not in content
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
