#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd -- "$script_dir/.." && pwd)"
python_bin=""
for candidate in "${PYTHON3_BIN:-}" python3 python; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        python_bin="$(command -v "$candidate")"
        break
    fi
done
[[ -n "$python_bin" ]] || {
    printf 'error: Python 3 is required for deployment asset verification\n' >&2
    exit 2
}

for script in "$script_dir"/*.sh; do
    bash -n "$script"
done

"$python_bin" - "$root_dir" <<'PY'
import ast
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
for path in root.joinpath('scripts').glob('*.py'):
    ast.parse(path.read_text(encoding='utf-8'), filename=str(path))

adapter_path = root / 'scripts' / 'prepare-novel-kdjx-adapter.py'
adapter_spec = importlib.util.spec_from_file_location(
    'prepare_novel_kdjx_adapter',
    adapter_path,
)
assert adapter_spec is not None and adapter_spec.loader is not None
adapter_module = importlib.util.module_from_spec(adapter_spec)
adapter_spec.loader.exec_module(adapter_module)

login_patch_path = root / 'scripts' / 'apply-sakura-only-login.py'

clean_head_config = """import path from 'node:path';

export const config = {
  bailianLaunchUrl: env('BAILIAN_LAUNCH_URL'),
  bailianSsoSharedSecret: env('BAILIAN_SSO_SHARED_SECRET'),
  bailianSsoTtlSeconds: Math.max(
    1,
    Math.min(60, Math.trunc(envNumber('BAILIAN_SSO_TTL_SECONDS', 60))),
  ),
  videoCoverDir: path.resolve(
    rootDir,
    env('VIDEO_COVER_DIR', './data/video-covers'),
  ),
};
"""
clean_head_routes = """import { enforceRateLimits } from './rate-limit.js';

export async function gameRoutes(app) {
  app.post('/games/bailian/sso-ticket', async () => ({ ok: true }));
}
"""
clean_head_env = """BAILIAN_LAUNCH_URL=https://49.232.137.85/bailian/
BAILIAN_SSO_SHARED_SECRET=
BAILIAN_SSO_TTL_SECONDS=60

VIDEO_COVER_DIR=./data/video-covers
VIDEO_COVER_MAX_BYTES=3145728
"""
clean_head_deploy = """#!/usr/bin/env bash
set -euo pipefail

healthy() {
  curl -fsS --max-time 5 "$health_url" >/dev/null
}

archive_entries="$(tar -tzf "$archive")"
for required in backend/package.json backend/package-lock.json backend/src/server.js backend/admin-dist/index.html; do
  grep -Fxq "$required" <<<"$archive_entries" || fail "archive_layout_invalid"
done

mv "$staged_dir" "$new_release"
chown -R "$app_user:$app_user" "$new_release"
"""
modao_config = """  modaoPaymentClaimTtlMs: Math.max(
    30000,
    Math.min(600000, Math.trunc(envNumber('MODAO_PAYMENT_CLAIM_TTL_MS', 60000))),
  ),
"""
modao_import = "import { modaoGameRoutes } from './routes-modao-game.js';"
modao_registration = "  app.register(modaoGameRoutes);"
modao_env = """MODAO_PAYMENT_TIMEOUT_MS=5000
MODAO_PAYMENT_CLAIM_TTL_MS=60000
"""


def write_adapter_fixture(fixture_root, include_modao=False):
    backend = fixture_root / 'backend'
    overlay = fixture_root / 'overlay'
    backend_src = backend / 'src'
    overlay_src = overlay / 'backend' / 'src'
    backend_src.mkdir(parents=True)
    (backend / 'scripts').mkdir()
    overlay_src.mkdir(parents=True)
    (overlay / 'backend' / 'catalogs').mkdir()

    config = clean_head_config
    routes = clean_head_routes
    env_example = clean_head_env
    if include_modao:
        config = config.replace(
            adapter_module.CONFIG_INSERT_ANCHOR,
            modao_config + adapter_module.CONFIG_INSERT_ANCHOR,
            1,
        )
        routes = routes.replace(
            adapter_module.GAME_ROUTES_ANCHOR,
            modao_import + "\n\n" + adapter_module.GAME_ROUTES_ANCHOR
            + modao_registration + "\n",
            1,
        )
        env_example = env_example.replace(
            adapter_module.ENV_EXAMPLE_INSERT_ANCHOR,
            "\n" + modao_env + adapter_module.ENV_EXAMPLE_INSERT_ANCHOR,
            1,
        )

    (backend_src / 'config.js').write_text(config, encoding='utf-8')
    (backend_src / 'routes-game.js').write_text(routes, encoding='utf-8')
    (backend / 'scripts' / 'deploy-production.sh').write_text(
        clean_head_deploy,
        encoding='utf-8',
    )
    (backend / '.env.example').write_text(env_example, encoding='utf-8')

    for name in adapter_module.KDJX_MODULE_NAMES:
        content = (
            "export async function kdjxGameRoutes() {}\n"
            if name == 'routes-kdjx-game.js'
            else "export {};\n"
        )
        (overlay_src / name).write_text(content, encoding='utf-8')
    (overlay / 'backend' / 'catalogs' / 'kdjx-payment-catalog.json').write_text(
        '{"schemaVersion":1}\n',
        encoding='utf-8',
    )
    return backend, overlay


def adapter_contents(backend):
    return {
        str(path.relative_to(backend)): path.read_bytes()
        for path in sorted(backend.rglob('*'))
        if path.is_file()
    }


def run_adapter(backend, overlay):
    subprocess.run(
        [
            sys.executable,
            str(adapter_path),
            '--backend-root',
            str(backend),
            '--overlay-root',
            str(overlay),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def assert_adapter_result(backend, include_modao=False):
    config = (backend / 'src' / 'config.js').read_text(encoding='utf-8')
    routes = (backend / 'src' / 'routes-game.js').read_text(encoding='utf-8')
    env_example = (backend / '.env.example').read_text(encoding='utf-8')
    deploy = (backend / 'scripts' / 'deploy-production.sh').read_text(
        encoding='utf-8',
    )

    assert config.count('kdjxDeviceAuthorizationUrl:') == 1
    assert config.count('kdjxLoginTicketTtlSeconds:') == 1
    assert routes.count(
        "import { kdjxGameRoutes } from './routes-kdjx-game.js';"
    ) == 1
    assert routes.count('  app.register(kdjxGameRoutes);') == 1
    assert env_example.count(
        'KDJX_DEVICE_AUTHORIZATION_URL=sakura-novel://game/kdjx/authorize'
    ) == 1
    assert env_example.count('KDJX_LOGIN_TICKET_TTL_SECONDS=60') == 1
    assert deploy.count('validate_kdjx_production_config()') == 1
    assert deploy.count('backend/catalogs/kdjx-payment-catalog.json') == 1
    assert "KDJX_LOGIN_TICKET_TTL_SECONDS: '60'" in deploy
    assert deploy.count(
        'chown -R "$app_user:$app_user" "$new_release"\n'
        'validate_kdjx_production_config\n'
    ) == 1
    assert 'videoCoverDir: path.resolve(' in config
    assert 'VIDEO_COVER_DIR=./data/video-covers' in env_example
    assert '/games/bailian/sso-ticket' in routes
    assert not (backend / 'src' / 'routes-modao-game.js').exists()

    if include_modao:
        assert config.count('modaoPaymentClaimTtlMs:') == 1
        assert routes.count(modao_import) == 1
        assert routes.count(modao_registration) == 1
        assert env_example.count('MODAO_PAYMENT_CLAIM_TTL_MS=60000') == 1
    else:
        assert 'modao' not in config.lower()
        assert 'modao' not in routes.lower()
        assert 'MODAO_' not in env_example


def assert_missing_anchor_fails(patch_function, source):
    with tempfile.TemporaryDirectory(prefix='kdjx-adapter-anchor-') as temp:
        target = pathlib.Path(temp) / 'fixture'
        target.write_text(source, encoding='utf-8')
        error_output = io.StringIO()
        with contextlib.redirect_stderr(error_output):
            try:
                patch_function(target)
            except SystemExit as error:
                assert error.code == 2
            else:
                raise AssertionError('adapter accepted a missing anchor')
        assert 'anchor does not match the supported release' in error_output.getvalue()


with tempfile.TemporaryDirectory(prefix='kdjx-adapter-clean-head-') as temp:
    clean_backend, clean_overlay = write_adapter_fixture(pathlib.Path(temp))
    run_adapter(clean_backend, clean_overlay)
    assert_adapter_result(clean_backend)
    first_result = adapter_contents(clean_backend)
    run_adapter(clean_backend, clean_overlay)
    assert adapter_contents(clean_backend) == first_result

with tempfile.TemporaryDirectory(prefix='kdjx-adapter-modao-') as temp:
    modao_backend, modao_overlay = write_adapter_fixture(
        pathlib.Path(temp),
        include_modao=True,
    )
    run_adapter(modao_backend, modao_overlay)
    assert_adapter_result(modao_backend, include_modao=True)
    first_result = adapter_contents(modao_backend)
    run_adapter(modao_backend, modao_overlay)
    assert adapter_contents(modao_backend) == first_result

assert_missing_anchor_fails(
    adapter_module.patch_config,
    "export const config = {};\n",
)
assert_missing_anchor_fails(
    adapter_module.patch_game_routes,
    "export async function unsupportedRoutes(app) {}\n",
)
assert_missing_anchor_fails(
    adapter_module.patch_env_example,
    "BAILIAN_SSO_TTL_SECONDS=60\n",
)

with tempfile.TemporaryDirectory(prefix='kdjx-login-ticket-gate-') as temp:
    runtime = pathlib.Path(temp) / 'runtime'
    login_root = runtime / 'gosrc' / 'tjgame' / 'login'
    task_source = login_root / 'checkin' / 'task' / 'check.go'
    verifier_source = login_root / 'sakuraauth' / 'client.go'
    verifier_test = verifier_source.with_name('client_test.go')
    task_source.parent.mkdir(parents=True)
    verifier_source.parent.mkdir(parents=True)
    task_source.write_text(
        'package task\n\n'
        'func check(t *Task) {\n'
        '\tlog.Infof("login channel `%s` tag `%s` guarder `%s`", t.Channel, t.Tag, t.Guarder)\n\n'
        '}\n',
        encoding='utf-8',
    )
    verifier_source.write_text(
        'package sakuraauth\n\n'
        'func (c *Client) Verify(clientName, clientPass string) (*Identity, error) {\n'
        '\tproof := strings.TrimSpace(clientName)\n'
        '\tif proof == "" || proof != strings.TrimSpace(clientPass) {\n'
        '\t\treturn nil, errors.New("sakura proof mismatch")\n'
        '\t}\n'
        '\tif !strings.HasPrefix(proof, "kdjx_session_") {\n'
        '\t\treturn nil, errors.New("unsupported sakura proof")\n'
        '\t}\n'
        '\t_, _ = json.Marshal(map[string]string{"credential": proof})\n'
        '\t_ = c.BaseURL+"/games/kdjx/sessions/verify"\n'
        '\treturn nil, nil\n'
        '}\n',
        encoding='utf-8',
    )
    verifier_test.write_text(
        'package sakuraauth\n\n'
        'func TestVerifyCredential(t *testing.T) {\n'
        '\tproof := "kdjx_session_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"\n'
        '\tbody := map[string]string{"credential": proof}\n'
        '\tif body["credential"] != proof {\n'
        '\t\tt.Fatal("credential was not forwarded")\n'
        '\t}\n'
        '}\n\n'
        'func TestVerifyRejectsMismatchedProof(t *testing.T) {\n'
        '\tclient := &Client{BaseURL: "https://example.invalid", SharedSecret: "secret"}\n'
        '\tif _, err := client.Verify("kdjx_session_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", "different"); err == nil {\n'
        '\t\tt.Fatal("expected mismatched proof to fail")\n'
        '\t}\n'
        '}\n\n'
        'func TestVerifyRejectsLongLivedSessionCredential(t *testing.T) {\n'
        '\tclient := &Client{BaseURL: "https://example.invalid", SharedSecret: "secret"}\n'
        '\tproof := "kdjx_session_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"\n'
        '\tif _, err := client.Verify(proof, proof); err == nil {\n'
        '\t\tt.Fatal("expected long-lived session credential to be rejected")\n'
        '\t}\n'
        '}\n',
        encoding='utf-8',
    )
    command = [
        sys.executable,
        str(login_patch_path),
        '--source-root',
        str(runtime),
    ]
    subprocess.run(command, check=True)
    first_result = {
        path: path.read_bytes()
        for path in (task_source, verifier_source, verifier_test)
    }
    subprocess.run(command, check=True)
    assert all(path.read_bytes() == payload for path, payload in first_result.items())
    patched_verifier = verifier_source.read_text(encoding='utf-8')
    patched_tests = verifier_test.read_text(encoding='utf-8')
    compatible_proof = (
        '\tnameProof := strings.TrimSpace(clientName)\n'
        '\tpassProof := strings.TrimSpace(clientPass)\n'
        '\tnameIsTicket := strings.HasPrefix(nameProof, "kdjx_login_")\n'
        '\tpassIsTicket := strings.HasPrefix(passProof, "kdjx_login_")\n'
    )
    assert patched_verifier.count(compatible_proof) == 1
    assert patched_verifier.count('proof := ""') == 1
    assert patched_verifier.count(
        'case nameIsTicket && passIsTicket && nameProof == passProof:'
    ) == 1
    assert patched_verifier.count('case nameIsTicket && !passIsTicket:') == 1
    assert patched_verifier.count('case passIsTicket && !nameIsTicket:') == 1
    assert patched_verifier.count('errors.New("sakura proof mismatch")') == 1
    assert 'map[string]string{"ticket": proof}' in patched_verifier
    assert 'kdjx_session_' not in patched_verifier
    assert 'body["ticket"]' in patched_tests
    assert patched_tests.count(
        'func TestVerifyAcceptsLoginTicketInEitherLegacyField('
    ) == 1
    assert patched_tests.count(
        'func TestVerifyRejectsConflictingLoginTickets('
    ) == 1
    assert patched_tests.count(
        'func TestVerifyRejectsLongLivedSessionCredential('
    ) == 1
    assert '{name: "both fields", clientName: proof, clientPass: proof}' in patched_tests
    assert 'if t.Channel != "sakura" {' in task_source.read_text(encoding='utf-8')

with tempfile.TemporaryDirectory(prefix='kdjx-runtime-verify-') as temp:
    runtime = pathlib.Path(temp) / 'runtime'
    src = runtime / 'release' / 'src'
    (src / 'framework' / 'service').mkdir(parents=True)
    (src / 'game' / 'object' / 'game').mkdir(parents=True)
    (src / 'nsqrpc').mkdir(parents=True)
    (src / 'payment').mkdir(parents=True)
    (runtime / 'release').mkdir(exist_ok=True)
    (runtime / 'release' / 'disable_words.txt').write_text(
        'normal-word\n58.253.67.74\n208.43.198.56\n', encoding='utf-8'
    )
    (src / 'framework' / 'monitor.py').write_text(
        "import socket\n"
        "class Monitor(object):\n"
        "\tdef local_ip(self):\n"
        "\t\ttempSock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
        "\t\ttempSock.connect(('8.8.8.8', 80))\n"
        "\t\taddr = tempSock.getsockname()[0]\n"
        "\t\ttempSock.close()\n"
        "\t\treturn addr\n",
        encoding='utf-8',
    )
    (src / 'framework' / 'log.py').write_text(
        "import sys\n"
        "# for test\n"
        "if __name__ == '__main__':\n"
        "\tsys.path.append('../')\n"
        "logger = None\n"
        "def initLog(name):\n"
        "\treturn name\n"
        "# for test\n"
        "if __name__ == '__main__':\n"
        "\tinitLog('test')\n",
        encoding='utf-8',
    )
    (src / 'framework' / 'service' / 'rpc_client.py').write_text(
        "DINGHEADERS = {\n'content-type': 'application/json'\n}\n"
        "DingURL = 'https://old.example.invalid/hook'\n\n"
        "def ding(msg):\n\tx = requests.post(DingURL)\n\tif x.status_code != 200:\n\t\tlogger.warning('%s', x.text)\n"
        "def nsqrpc_coroutine(f):\n\treturn f\n",
        encoding='utf-8',
    )
    (src / 'game' / 'object' / 'game' / 'endlesstower.py').write_text(
        "import requests\n\n"
        "class Tower(object):\n"
        "\tDingURL = 'https://old.example.invalid/hook'\n\n"
        "\t@classmethod\n"
        "\tdef ding(cls, msg):\n"
        "\t\tx = requests.post(cls.DingURL)\n"
        "\t\tif x.status_code != 200:\n"
        "\t\t\tlogger.warning('%s', x.text)\n",
        encoding='utf-8',
    )
    subprocess.run(
        [sys.executable, str(root / 'scripts' / 'generate-runtime-config.py'), '--runtime-root', str(runtime)],
        check=True,
    )
    # Full runtime auditing has no vendored-source exception. The sanitizer
    # neutralizes an inherited documentation URL before the release audit.
    (src / 'vendor_doc.py').write_text(
        "DOC_URL = 'https://legacy.example.invalid/api'\nDEBUG_HOST = 'localhost'\n",
        encoding='utf-8',
    )
    go_source = runtime / 'gosrc' / 'tjgame' / 'endpoint_fixture.go'
    go_source.parent.mkdir(parents=True)
    go_source.write_text(
        'package tjgame\nconst endpoint = "http://192.168.1.99/legacy"\n',
        encoding='utf-8',
    )
    version_source = runtime / 'gosrc' / 'tjgame' / 'login' / 'diff' / 'init.go'
    version_source.parent.mkdir(parents=True)
    version_source.write_text(
        'package diff\n'
        'var (\n'
        '\tversion = "2.1.0.0"\n'
        '\tlegacyEndpoint = "2.1.0.0:16666"\n'
        ')\n',
        encoding='utf-8',
    )
    subprocess.run(
        [sys.executable, str(root / 'scripts' / 'sanitize-kdjx-runtime-inputs.py'), '--runtime-root', str(runtime)],
        check=True,
    )
    (runtime / 'sakura-only-login-gate.txt').write_text('sakura-only-login-ticket-gate-v2\n', encoding='utf-8')
    (runtime / 'loopback-metrics-gate.txt').write_text('loopback-metrics-gate-v1\n', encoding='utf-8')
    runtime_audit = runtime / 'scripts' / 'audit-runtime-addresses.py'
    runtime_audit.parent.mkdir(parents=True)
    shutil.copyfile(root / 'scripts' / 'audit-runtime-addresses.py', runtime_audit)
    shutil.copyfile(root / 'scripts' / 'kdjx_env.py', runtime / 'scripts' / 'kdjx_env.py')
    shutil.copyfile(
        root / 'scripts' / 'healthcheck-kdjx-runtime.sh',
        runtime / 'scripts' / 'healthcheck-kdjx-runtime.sh',
    )
    runtime_env_validator = runtime / 'scripts' / 'validate-runtime-env.py'
    shutil.copyfile(root / 'scripts' / 'validate-runtime-env.py', runtime_env_validator)
    gm_env_validator = runtime / 'scripts' / 'validate-gm-env.py'
    shutil.copyfile(root / 'scripts' / 'validate-gm-env.py', gm_env_validator)
    subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        check=True,
    )
    channel_path = runtime / 'login' / 'conf' / 'channel.json'
    channel_payload = json.loads(channel_path.read_text(encoding='utf-8'))
    assert channel_payload == {
        'channels': {'sakura': ['game.cn']},
        'guarder': '1b5a8aa9e7660d317d1eada5c37d2429',
        'servers': {},
    }
    channel_payload['guarder'] = ''
    channel_path.write_text(
        json.dumps(channel_payload, indent=2, sort_keys=True) + '\n',
        encoding='utf-8',
    )
    guarder_blocked = subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert guarder_blocked.returncode == 2
    assert b'login guarder MD5' in guarder_blocked.stderr
    channel_payload['guarder'] = '1b5a8aa9e7660d317d1eada5c37d2429'
    channel_path.write_text(
        json.dumps(channel_payload, indent=2, sort_keys=True) + '\n',
        encoding='utf-8',
    )
    module_spec = importlib.util.spec_from_file_location('runtime_env_validator', runtime_env_validator)
    runtime_env_module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(runtime_env_module)
    valid_environment = {
        'KDJX_RUNTIME_ROOT': '/opt/kdjx/runtime/current',
        'KDJX_NOVEL_API_URL': 'http://127.0.0.1:3010/novel-api',
        'KDJX_SSO_SHARED_SECRET': 's' * 32,
        'KDJX_PAYMENT_HMAC_SECRET': 'p' * 32,
        'KDJX_MONGO_URI': 'mongodb://127.0.0.1:27159',
        'KDJX_PYTHON_IMAGE': 'kdjx-legacy-python:2.7',
    }
    runtime_env_module.validate_values(valid_environment)
    invalid_environment = dict(valid_environment)
    invalid_environment['KDJX_NOVEL_API_URL'] = 'https://legacy.example.invalid/novel-api'
    try:
        runtime_env_module.validate_values(invalid_environment)
    except ValueError as exc:
        assert str(exc) == 'runtime_env_kdjx_novel_api_url_invalid'
    else:
        raise AssertionError('unexpected Novel verifier was accepted')
    gm_module_spec = importlib.util.spec_from_file_location('gm_env_validator', gm_env_validator)
    gm_env_module = importlib.util.module_from_spec(gm_module_spec)
    gm_module_spec.loader.exec_module(gm_env_module)
    valid_gm_environment = {
        'KDJX_GM_HMAC_SECRET': 'g' * 32,
        'KDJX_GM_ITEM_CATALOG_FILE': '/opt/kdjx/runtime/current/kdjx-gm-item-catalog.json',
    }
    gm_env_module.validate_values(valid_gm_environment)
    catalog_spec = importlib.util.spec_from_file_location(
        'gm_catalog_validator',
        root / 'scripts' / 'validate-kdjx-gm-item-catalog.py',
    )
    catalog_module = importlib.util.module_from_spec(catalog_spec)
    catalog_spec.loader.exec_module(catalog_module)
    builder_spec = importlib.util.spec_from_file_location(
        'gm_catalog_builder',
        root / 'scripts' / 'build-kdjx-gm-item-catalog.py',
    )
    builder_module = importlib.util.module_from_spec(builder_spec)
    builder_spec.loader.exec_module(builder_module)
    fixture_items_lua = runtime / 'items.lua'
    fixture_items_lua.write_text(
        "csv['items'] = {\n"
        "\t[1001] = {\n"
        "\t\tid = 1001,\n"
        "\t\tname = 'Fixture item',\n"
        "\t\tdesc = 'Fixture item description',\n"
        "\t\tquality = 1,\n"
        "\t\ttype = 1,\n"
        "\t\tstackMax = 99,\n"
        "\t},\n"
        "\t[1002] = {\n"
        "\t\tid = 1002,\n"
        "\t\tname = 'Internal test item',\n"
        "\t\tdesc = 'Must not enter the GM catalog',\n"
        "\t\tquality = 6,\n"
        "\t\ttype = 15,\n"
        "\t},\n"
        "\t__size = 2,\n"
        "}\n",
        encoding='utf-8',
    )
    valid_catalog = builder_module.build_catalog(fixture_items_lua)
    assert valid_catalog['sourceItemCount'] == 2
    assert valid_catalog['itemCount'] == 1
    assert [item['id'] for item in valid_catalog['items']] == [1001]
    catalog_module.validate_catalog(valid_catalog)
    catalog_module.validate_source(valid_catalog, fixture_items_lua)
    invalid_catalog = dict(valid_catalog)
    invalid_catalog['items'] = [dict(valid_catalog['items'][0], id=-1)]
    try:
        catalog_module.validate_catalog(invalid_catalog)
    except ValueError as exc:
        assert str(exc) == 'gm_catalog_item_invalid'
    else:
        raise AssertionError('invalid GM item catalog was accepted')
    mismatched_catalog = json.loads(json.dumps(valid_catalog))
    mismatched_catalog['items'][0]['name'] = 'Tampered item'
    try:
        catalog_module.validate_source(mismatched_catalog, fixture_items_lua)
    except ValueError as exc:
        assert str(exc) == 'gm_catalog_source_mismatch'
    else:
        raise AssertionError('mismatched GM item catalog was accepted')
    with tempfile.TemporaryDirectory(prefix='kdjx-payment-rpc-verify-') as payment_temp:
        payment_source = pathlib.Path(payment_temp)
        payment_game_service = (
            payment_source / 'gosrc' / 'tjgame' / 'services' / 'game' / 'service.go'
        )
        payment_bridge = (
            payment_source / 'gosrc' / 'tjgame' / 'login' / 'sakura_payments.go'
        )
        payment_role_schema = (
            payment_source / 'gosrc' / 'tjgame' / 'document' / 'scheme' / 'Role.go'
        )
        payment_rpc = payment_source / 'release' / 'src' / 'game' / 'rpc.py'
        payment_handler = (
            payment_source / 'release' / 'src' / 'game' / 'handler' / '_game.py'
        )
        payment_game_service.parent.mkdir(parents=True)
        payment_bridge.parent.mkdir(parents=True)
        payment_role_schema.parent.mkdir(parents=True)
        payment_rpc.parent.mkdir(parents=True)
        payment_handler.parent.mkdir(parents=True)
        payment_game_service.write_text(
            'package game\n\n'
            'import (\n'
            '\t"tjgame/document"\n'
            '\t"tjgame/server_framework/tj/service"\n'
            ')\n\n'
            'type Service struct {\n\t*service.Service\n}\n\n'
            'func (s *Service) GetOpenDays() (int, error) {\n'
            '\treturn 0, nil\n'
            '}\n\n'
            'func NewService(option service.IOption, container service.IContainer) service.IService {\n'
            '\ts := &Service{Service: service.NewService(option, container)}\n'
            '\ts.Register(s, "GetOpenDays")\n'
            '\treturn s\n'
            '}\n',
            encoding='utf-8',
        )
        payment_bridge.write_text(
            'package main\n\n'
            'func paymentBridgeMarkers() {\n'
            '\tHandle("/internal/sakura/payments/verify")\n'
            '\tHandle("/internal/sakura/payments/fulfill")\n'
            '\tCall("VerifySakuraPayment")\n'
            '\tCall("PayForRecharge")\n'
            '}\n',
            encoding='utf-8',
        )
        payment_role_schema.write_text(
            'package scheme\n\n'
            'import "tjgame/document"\n\n'
            'type RechargeCache struct {\n'
            '\t_struct struct{} `codec:",toarray"`\n'
            '\n'
            '\tRechargeID int         `codec:"recharge_id" bson:"recharge_id"`\n'
            '\tOrderID    document.ID `codec:"order_id" bson:"order_id"`\n'
            '\tYYID       int         `codec:"yy_id" codec:"yy_id"`\n'
            '\tCSVID      int         `codec:"csv_id" codec:"csv_id"`\n'
            '}\n',
            encoding='utf-8',
        )
        payment_rpc.write_text(
            'class GameRPC(object):\n'
            '\tdef VerifySakuraPayment(self, inl_pwd, rechargeID, amountYuan, yyID=0, csvID=0):\n'
            '\t\tif inl_pwd != GameServInternalPassword:\n'
            "\t\t\treturn 'no auth'\n"
            '\t\tif rechargeID not in csv.recharges:\n'
            "\t\t\treturn 'invalid product'\n"
            "\t\treturn 'ok:600'\n"
            '\n'
            '\t@rpc_coroutine\n'
            '\tdef PayForRecharge(self, inl_pwd, channel, accountID, roleID, rechargeID, orderID, amount, extInfo=None, yyID=0, csvID=0):\n'
            '\t\tif inl_pwd != GameServInternalPassword:\n'
            "\t\t\traise Return('no auth')\n"
            '\t\tif game is None:\n'
            '\t\t\tif rechargeOK:\n'
            "\t\t\t\trole = {'recharges_cache': []}\n"
            "\t\t\t\trecharges_cache = role['recharges_cache']\n"
            '\t\t\t\trecharges_cache.append((rechargeID, orderID, yyID, csvID, rePro))\n'
            "\t\traise Return('ok')\n",
            encoding='utf-8',
        )
        payment_handler.write_text(
            'class GameLoginHandler(object):\n'
            '\tdef replayRechargeCache(self, role):\n'
            '\t\tif role.recharges_cache:\n'
            '\t\t\tfor t in role.recharges_cache:\n'
            '\t\t\t\tif len(t)==4: # 可能存在的更新前的老订单\n'
            '\t\t\t\t\trechargeID, orderID, yyID, csvID = t\n'
            '\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID)\n'
            '\t\t\t\telse:\n'
            '\t\t\t\t\trechargeID, orderID, yyID, csvID, rePro = t\n'
            '\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID, rePro=rePro)\n'
            '\t\t\trole.recharges_cache = []\n',
            encoding='utf-8',
        )
        payment_patch_command = [
            sys.executable,
            str(root / 'scripts' / 'apply-sakura-payment-rpc.py'),
            '--source-root',
            str(payment_source),
        ]
        subprocess.run(payment_patch_command, check=True)
        subprocess.run(payment_patch_command, check=True)
        payment_service_text = payment_game_service.read_text(encoding='utf-8')
        for method in ('VerifySakuraPayment', 'PayForRecharge'):
            assert payment_service_text.count(
                'func (s *Service) {}('.format(method)
            ) == 1
            assert payment_service_text.count(
                's.Register(s, "{}")'.format(method)
            ) == 1
            assert payment_service_text.index(
                'func (s *Service) {}('.format(method)
            ) < payment_service_text.index('func NewService(')
        assert 'amountYuan string' in payment_service_text
        assert 'accountID document.ID' in payment_service_text
        assert 'orderID document.ID' in payment_service_text
        payment_rpc_tree = ast.parse(
            payment_rpc.read_text(encoding='utf-8'),
            filename=str(payment_rpc),
        )
        payment_rpc_class = next(
            node for node in payment_rpc_tree.body
            if isinstance(node, ast.ClassDef) and node.name == 'GameRPC'
        )
        assert [
            node.name for node in payment_rpc_class.body
            if isinstance(node, ast.FunctionDef)
        ] == ['VerifySakuraPayment', 'PayForRecharge']
        payment_rpc_text = payment_rpc.read_text(encoding='utf-8')
        payment_handler_text = payment_handler.read_text(encoding='utf-8')
        payment_role_schema_text = payment_role_schema.read_text(encoding='utf-8')
        ast.parse(payment_handler_text, filename=str(payment_handler))
        assert payment_rpc_text.count(
            'recharges_cache.append((rechargeID, orderID, yyID, csvID, rePro, channel))'
        ) == 1
        assert payment_handler_text.count("channel='sakura'") == 2
        assert payment_handler_text.count("channel=channel or 'sakura'") == 1
        assert payment_handler_text.count('elif len(t) == 5:') == 1
        assert payment_role_schema_text.count(
            'RePro      int         `codec:"re_pro" bson:"re_pro"`'
        ) == 1
        assert payment_role_schema_text.count(
            'Channel    string      `codec:"channel" bson:"channel"`'
        ) == 1

        replay_namespace = {}
        exec(
            compile(payment_handler_text, str(payment_handler), 'exec'),
            replay_namespace,
        )

        class ReplayRole(object):
            def __init__(self):
                self.recharges_cache = [
                    (9, 'order-4', 0, 0),
                    (9, 'order-5', 0, 0, 25),
                    (9, 'order-6-empty', 0, 0, 0, ''),
                    (9, 'order-6-sakura', 0, 0, 0, 'sakura'),
                ]
                self.calls = []

            def buyRecharge(self, *args, **kwargs):
                self.calls.append((args, kwargs))

        replay_role = ReplayRole()
        replay_namespace['GameLoginHandler']().replayRechargeCache(replay_role)
        assert replay_role.recharges_cache == []
        assert [call[1].get('channel') for call in replay_role.calls] == [
            'sakura', 'sakura', 'sakura', 'sakura',
        ]
        assert [call[1].get('rePro', 0) for call in replay_role.calls] == [
            0, 25, 0, 0,
        ]
    with tempfile.TemporaryDirectory(prefix='kdjx-gm-patch-verify-') as gm_temp:
        gm_source = pathlib.Path(gm_temp)
        gm_server = gm_source / 'gosrc' / 'tjgame' / 'login' / 'server.go'
        gm_game_service = (
            gm_source / 'gosrc' / 'tjgame' / 'services' / 'game' / 'service.go'
        )
        gm_rpc = gm_source / 'release' / 'src' / 'game' / 'rpc.py'
        gm_server.parent.mkdir(parents=True)
        gm_game_service.parent.mkdir(parents=True)
        gm_rpc.parent.mkdir(parents=True)
        gm_server.write_text(
            'package main\nfunc (s *Server) initServices() {\n'
            '\ts.initSakuraPayments()\n}\n',
            encoding='utf-8',
        )
        # This is the smallest fixture that preserves the production game
        # service constructor and registration anchors. The generated stub is
        # metadata for the remote RPCCaller; without both the method and the
        # Register call, CanCall rejects the request before NSQ dispatch.
        gm_game_service.write_text(
            'package game\n\n'
            'import (\n'
            '\t"tjgame/document"\n'
            '\t"tjgame/server_framework/tj/service"\n'
            ')\n\n'
            'type Service struct {\n\t*service.Service\n}\n\n'
            'func (s *Service) GetOpenDays() (int, error) {\n'
            '\treturn 0, nil\n'
            '}\n\n'
            'func NewService(option service.IOption, container service.IContainer) service.IService {\n'
            '\ts := &Service{Service: service.NewService(option, container)}\n'
            '\ts.Register(s, "GetOpenDays")\n'
            '\treturn s\n'
            '}\n',
            encoding='utf-8',
        )
        gm_rpc.write_text(
            'class GameRPC(object):\n'
            '\t@rpc_coroutine\n'
            '\tdef gmSendMail(self, roleID, mailType, sender, subject, content, attachs):\n'
            '\t\tself.original_mail_body = roleID\n'
            '\t\treturn self.original_mail_body\n',
            encoding='utf-8',
        )
        gm_patch_command = [
            sys.executable,
            str(root / 'scripts' / 'apply-sakura-gm-delivery.py'),
            '--source-root',
            str(gm_source),
            '--patch-root',
            str(root / 'patches' / 'sakura-gm'),
        ]
        subprocess.run(gm_patch_command, check=True)
        subprocess.run(gm_patch_command, check=True)
        gm_server_text = gm_server.read_text(encoding='utf-8')
        gm_game_service_text = gm_game_service.read_text(encoding='utf-8')
        gm_rpc_text = gm_rpc.read_text(encoding='utf-8')
        assert gm_server_text.count('s.initSakuraGMDelivery()') == 1
        assert gm_game_service_text.count(
            'func (s *Service) SakuraGMSendMail('
        ) == 1
        assert gm_game_service_text.count(
            's.Register(s, "SakuraGMSendMail")'
        ) == 1
        assert gm_game_service_text.index(
            'func (s *Service) SakuraGMSendMail('
        ) < gm_game_service_text.index('func NewService(')
        assert 'roleID document.ID' in gm_game_service_text
        assert 'attachs map[document.Integer]int' in gm_game_service_text
        assert gm_rpc_text.count('def SakuraGMSendMail(') == 1
        assert 'mailbox = copy.deepcopy(game.role.mailbox)' in gm_rpc_text
        assert gm_rpc_text.count(
            "'DBUpdate', 'Role', roleID, {'mailbox': mailbox}, False"
        ) == 1
        assert gm_rpc_text.count(
            "'DBMultipleReadKeys', 'Role', [roleID], ['mailbox']"
        ) == 2
        gm_rpc_tree = ast.parse(gm_rpc_text, filename=str(gm_rpc))
        gm_rpc_class = next(
            node for node in gm_rpc_tree.body
            if isinstance(node, ast.ClassDef) and node.name == 'GameRPC'
        )
        gm_rpc_methods = [
            node for node in gm_rpc_class.body if isinstance(node, ast.FunctionDef)
        ]
        assert [node.name for node in gm_rpc_methods] == [
            'SakuraGMSendMail',
            'gmSendMail',
        ]
        original_mail_method = gm_rpc_methods[1]
        assert any(
            isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Attribute)
                and target.attr == 'original_mail_body'
                for target in node.targets
            )
            for node in original_mail_method.body
        )
        python2 = shutil.which('python2.7') or shutil.which('python2')
        if python2:
            subprocess.run([python2, '-m', 'py_compile', str(gm_rpc)], check=True)
        assert gm_rpc_text.index("raise Return('ok:'") > gm_rpc_text.index(
            "logger.exception('SakuraGMSendMail error"
        )
    login = json.loads((runtime / 'login' / 'defines.json').read_text(encoding='utf-8'))
    assert login['login.cn.1']['patch_url'] == 'https://novel.kxhub.xyz/games/kdjx/hot/'
    game_defines = (runtime / 'release' / 'game_defines.py').read_text(encoding='utf-8')
    assert "'game.cn.1'" in game_defines
    assert "'port': 28879" in game_defines
    assert 'game.cn.2' not in game_defines
    assert '28878' not in game_defines
    rpdb_stub = (runtime / 'release' / 'src' / 'rpdb.py').read_text(encoding='utf-8')
    assert "raise RuntimeError('remote debugger disabled')" in rpdb_stub
    analytics_stub = (runtime / 'release' / 'src' / 'tgasdk' / 'sdk.py').read_text(encoding='utf-8')
    for method in ('track', 'user_set', 'user_setOnce', 'flush'):
        assert 'def {}('.format(method) in analytics_stub
    assert 'http://' not in analytics_stub and 'https://' not in analytics_stub
    service_entries = json.loads(
        (runtime / 'release' / 'serv.conf').read_text(encoding='utf-8')
    )
    assert service_entries == [{
        'id': 1,
        'key': 'game.cn.1',
        'name': 'Sakura I',
        'url': 'http://49.232.137.85:28879',
        'description': '',
    }]
    assert (runtime / 'login' / 'conf' / 'cn' / 'names.json').is_file()
    assert (runtime / 'login' / 'conf' / 'cn' / 'maintain.json').is_file()
    assert (runtime / 'login' / 'conf' / 'test.json').is_file()
    assert (runtime / 'login' / 'blacklist' / 'global.json').is_file()
    assert '58.253.67.74' not in (runtime / 'release' / 'disable_words.txt').read_text(encoding='utf-8')
    assert 'legacy.example.invalid' not in (src / 'vendor_doc.py').read_text(encoding='utf-8')
    assert 'localhost' not in (src / 'vendor_doc.py').read_text(encoding='utf-8')
    assert '192.168.1.99' not in go_source.read_text(encoding='utf-8')
    sanitized_version_source = version_source.read_text(encoding='utf-8')
    assert 'version = "2.1.0.0"' in sanitized_version_source
    assert 'legacyEndpoint = "127.0.0.1:16666"' in sanitized_version_source
    log_source = (src / 'framework' / 'log.py').read_text(encoding='utf-8')
    assert 'def initLog(name):' in log_source
    assert "sys.path.append('../')" in log_source
    assert "initLog('test')" not in log_source

    # Go links OpenXML/Protobuf namespace metadata into its executable. It is
    # allowed only in bin/, while an actual external endpoint remains blocked.
    metadata_binary = runtime / 'bin' / 'metadata-fixture'
    metadata_binary.parent.mkdir(parents=True)
    metadata_binary.write_bytes(
        b'\x00http://schemas.openxmlformats.org/officeDocument/2006/'
        b'relationships/sharedStringscollected\x00'
        b'https://developers.google.com/protocol-buffers/docs/reference/go/'
        b'faq#namespace-conflict\x00'
    )
    subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        check=True,
    )
    metadata_binary.unlink()

    # The KDJX version looks like IPv4. It is permitted only as the single
    # compiled version constant in the login binary; another binary cannot use
    # the same dotted value to bypass endpoint auditing.
    login_binary = runtime / 'bin' / 'login_server'
    login_binary.write_bytes(b'\x00kdjx-version=2.1.0.0\x00')
    subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        check=True,
    )
    foreign_version_binary = runtime / 'bin' / 'host_server'
    foreign_version_binary.write_bytes(b'\x00kdjx-version=2.1.0.0\x00')
    blocked = subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert blocked.returncode != 0
    assert b'binary-ip' in blocked.stderr
    foreign_version_binary.unlink()
    login_binary.unlink()

    # Go emits anonymous-function symbol suffixes such as ``func1.1.1.1``.
    # They are not endpoints, but the same bare literal outside a symbol must
    # still fail the binary audit.
    go_symbol_binary = runtime / 'bin' / 'go-symbol-fixture'
    go_symbol_binary.write_bytes(
        b'\x00crypto/tls.(*fixture).marshal.func1.1.1.1.1\x00'
    )
    subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        check=True,
    )
    go_symbol_binary.write_bytes(b'\x00legacy-build-host=1.1.1.1\x00')
    blocked = subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert blocked.returncode != 0
    assert b'binary-ip' in blocked.stderr
    go_symbol_binary.unlink()

    # A binary string cannot bypass the endpoint allow-list, including a
    # serialized runtime input outside bin/.
    binary = runtime / 'release' / 'endpoint-fixture.msgpack'
    binary.write_bytes(b'\x00http://203.0.113.9/legacy\x00')
    blocked = subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert blocked.returncode != 0
    assert b'binary-' in blocked.stderr
    binary.unlink()

    # A legacy public address can be compiled as a bare string with its port
    # assembled at runtime. It must be rejected just as strictly as a URL.
    binary = runtime / 'bin' / 'public-address-fixture'
    binary.write_bytes(b'\x00old-build-host=8.8.8.8\x00')
    blocked = subprocess.run(
        [sys.executable, str(runtime_audit), '--runtime-root', str(runtime)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert blocked.returncode != 0
    assert b'binary-ip' in blocked.stderr
    binary.unlink()

with tempfile.TemporaryDirectory(prefix='kdjx-python-runner-verify-') as temp:
    def shell_path(path):
        if os.name != 'nt':
            return str(path)
        windows_path = pathlib.PureWindowsPath(path)
        drive = windows_path.drive.rstrip(':').lower()
        return '/{}/{}'.format(drive, windows_path.relative_to(windows_path.anchor).as_posix())

    fixture = pathlib.Path(temp)
    runtime = fixture / 'runtime'
    release = runtime / 'release'
    log_mount_point = release / 'logs'
    log_mount_point.mkdir(parents=True)
    (release / 'game_server.py').write_text('# fixture\n', encoding='utf-8')

    fake_bin = fixture / 'bin'
    fake_bin.mkdir()
    docker_args = fixture / 'docker-args'
    docker_cleanup = fixture / 'docker-cleanup'
    fake_docker = fake_bin / 'docker'
    fake_docker.write_text(
        '#!/usr/bin/env bash\n'
        'set -eu\n'
        'if [[ "${1:-}" == "image" ]]; then exit 0; fi\n'
        'if [[ "${1:-}" == "container" ]]; then\n'
        '  [[ -n "${KDJX_TEST_STALE_CONTAINER:-}" ]] || exit 1\n'
        '  printf "%s\\n" "$KDJX_TEST_STALE_CONTAINER"\n'
        '  exit 0\n'
        'fi\n'
        'if [[ "${1:-}" == "rm" ]]; then\n'
        '  printf "%s\\n" "$@" > "$KDJX_TEST_DOCKER_CLEANUP"\n'
        '  exit 0\n'
        'fi\n'
        'printf "%s\\n" "$@" > "$KDJX_TEST_DOCKER_ARGS"\n',
        encoding='utf-8',
    )
    bash_environment = fake_bin / 'test-env.sh'
    bash_environment.write_text('install() { :; }\n', encoding='utf-8')
    fake_docker.chmod(0o750)
    bash_environment.chmod(0o640)

    environment = os.environ.copy()
    test_path = str(fake_bin) + os.pathsep + environment.get('PATH', '')
    if os.name == 'nt':
        test_path = shell_path(fake_bin) + ':/usr/bin:/bin'
    environment.update({
        'PATH': test_path,
        'KDJX_RUNTIME_ROOT': shell_path(runtime),
        'KDJX_PYTHON_IMAGE': 'kdjx-legacy-python:2.7',
        'KDJX_TEST_DOCKER_ARGS': shell_path(docker_args),
        'KDJX_TEST_DOCKER_CLEANUP': shell_path(docker_cleanup),
        'BASH_ENV': shell_path(bash_environment),
    })
    runner = root / 'scripts' / 'run-python-game.sh'
    bash_bin = environment.get('KDJX_VERIFY_BASH', 'bash')
    launched = subprocess.run(
        [bash_bin, shell_path(runner), '1'],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert launched.returncode == 0, (
        'runner launch failed: rc={} stdout={!r} stderr={!r}'.format(
            launched.returncode,
            launched.stdout.decode('utf-8', errors='replace'),
            launched.stderr.decode('utf-8', errors='replace'),
        )
    )
    arguments = docker_args.read_text(encoding='utf-8').splitlines()
    parent_mount = 'type=bind,source={},target=/app,readonly'.format(shell_path(release))
    log_mount = 'type=bind,source=/var/log/kdjx/game-1,target=/app/logs'
    assert parent_mount in arguments
    assert log_mount in arguments
    assert arguments.index(parent_mount) < arguments.index(log_mount)
    assert not docker_cleanup.exists()

    docker_args.unlink()
    environment['KDJX_TEST_STALE_CONTAINER'] = 'created'
    launched = subprocess.run(
        [bash_bin, shell_path(runner), '1'],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert launched.returncode == 0
    assert docker_cleanup.read_text(encoding='utf-8').splitlines() == [
        'rm', '--', 'kdjx-game-1',
    ]
    assert docker_args.is_file()

    docker_args.unlink()
    docker_cleanup.unlink()
    environment['KDJX_TEST_STALE_CONTAINER'] = 'running'
    rejected_running = subprocess.run(
        [bash_bin, shell_path(runner), '1'],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert rejected_running.returncode == 2
    assert b'game container is already running' in rejected_running.stderr
    assert not docker_args.exists()
    assert not docker_cleanup.exists()
    environment.pop('KDJX_TEST_STALE_CONTAINER')

    log_mount_point.rmdir()
    rejected = subprocess.run(
        [bash_bin, shell_path(runner), '1'],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert rejected.returncode == 2
    assert b'log mount point is missing' in rejected.stderr
    assert not docker_args.exists()

with tempfile.TemporaryDirectory(prefix='kdjx-input-sanitize-verify-') as temp:
    source = pathlib.Path(temp)
    patch = source / 'patch'
    anti = source / 'anti'
    (patch / 'cn').mkdir(parents=True)
    (patch / 'cn' / '8.json').write_text(
        json.dumps({'id': 8, 'callback': 'http://192.168.1.99/legacy'}), encoding='utf-8'
    )
    game_net = anti / 'application' / 'src' / 'app' / 'game_net.lua'
    game_net.parent.mkdir(parents=True)
    game_net.write_text(
        "self.noticeUrl = 'http://192.168.1.99:18080/notice'\n"
        "self.versionUrl = 'http://192.168.1.99:18080/version'\n"
        "self.serverUrl = 'http://192.168.1.99:18080/servers'\n"
        "self.loginAddress = '192.168.1.99:16666'\n"
        "self.loginHost = '192.168.1.99'\n"
        "self.gameHost = '192.168.1.99'\n"
        "self.gamePort = 18080\n",
        encoding='utf-8',
    )
    none = anti / 'application' / 'src' / 'app' / 'sdk' / 'none.lua'
    none.parent.mkdir(parents=True)
    none.write_text(
        "local none = {}\nlocal url = 'http://202.189.12.86:28089/tjgame/payment'\nreturn none\n",
        encoding='utf-8',
    )
    malformed = anti / 'application' / 'src' / 'malformed_url.lua'
    malformed.write_text(
        "local callback = 'http://[legacy-endpoint'\n",
        encoding='utf-8',
    )
    clean = source / 'clean'
    subprocess.run(
        [
            sys.executable,
            str(root / 'scripts' / 'sanitize-kdjx-runtime-inputs.py'),
            '--patch-source', str(patch),
            '--anti-cheat-source', str(anti),
            '--output', str(clean),
        ],
        check=True,
    )
    clean_game_net = (clean / 'anti-cheat-scripts' / 'application' / 'src' / 'app' / 'game_net.lua').read_text(encoding='utf-8')
    assert 'https://49.232.137.85/kdjx/notice' in clean_game_net
    assert '192.168.1.99' not in clean_game_net
    clean_none = (clean / 'anti-cheat-scripts' / 'application' / 'src' / 'app' / 'sdk' / 'none.lua').read_text(encoding='utf-8')
    assert '202.189.12.86' not in clean_none
    assert 'sakura_payment_required' in clean_none
    clean_malformed = (clean / 'anti-cheat-scripts' / 'application' / 'src' / 'malformed_url.lua').read_text(encoding='utf-8')
    assert 'http://[legacy-endpoint' not in clean_malformed
    assert 'https://49.232.137.85/kdjx/feedback' in clean_malformed

with tempfile.TemporaryDirectory(prefix='kdjx-login-patches-verify-') as temp:
    fixture = pathlib.Path(temp)
    source = fixture / 'source'
    candidate = fixture / 'candidate'
    source_channel = source / 'cn'
    candidate_channel = candidate / 'cn'
    source_channel.mkdir(parents=True)
    candidate_channel.mkdir(parents=True)
    required_descriptors = (8, 9, 11, 12, 13, 14, 15, 16, 17)
    for number in required_descriptors:
        payload = json.dumps({'files': [], 'patch': number})
        (source_channel / '{}.json'.format(number)).write_text(payload, encoding='utf-8')
        (candidate_channel / '{}.json'.format(number)).write_text(payload, encoding='utf-8')
    validator = root / 'scripts' / 'validate-kdjx-login-patches.py'
    validator_command = [
        sys.executable,
        str(validator),
        '--source',
        str(source),
        '--candidate',
        str(candidate),
    ]
    subprocess.run(validator_command, check=True)

    (source_channel / '17.json').unlink()
    missing_required = subprocess.run(
        [sys.executable, str(validator), '--source', str(source)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert missing_required.returncode == 2
    assert b'17.json' in missing_required.stderr
    payload = json.dumps({'files': [], 'patch': 17})
    (source_channel / '17.json').write_text(payload, encoding='utf-8')

    (candidate_channel / '15.json').unlink()
    not_preserved = subprocess.run(
        validator_command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert not_preserved.returncode == 2
    assert b'not preserved' in not_preserved.stderr
    assert b'15.json' in not_preserved.stderr

with tempfile.TemporaryDirectory(prefix='kdjx-go-hardening-verify-') as temp:
    source = pathlib.Path(temp)
    main = source / 'gosrc' / 'tjgame' / 'anti_cheat' / 'main.go'
    main.parent.mkdir(parents=True)
    forward = source / 'gosrc' / 'tjgame' / 'services' / 'cross' / 'onlinefight' / 'forward' / 'service.go'
    forward.parent.mkdir(parents=True)
    proxy = forward.with_name('proxy.go')
    rpcserver = source / 'gosrc' / 'tjgame' / 'server_framework' / 'tj' / 'nsq' / 'rpcserver.go'
    rpcserver.parent.mkdir(parents=True)
    main.write_text(
        "import (\n"
        "\t\"fmt\"\n"
        "\t\"tjgame/server_framework/tj/util\"\n"
        ")\n"
        "func main() {\n"
        "\tlocalIP := util.GetLocalIP()\n"
        "\taddr := fmt.Sprintf(\"%s:2112\", localIP)\n"
        "}\n",
        encoding='utf-8',
    )
    forward.write_text(
        "package forward\n"
        "func (s *Service) Stop() {\n"
        "\trunner := s.runner.Load()\n"
        "\tif runner != nil {\n"
        "\t\trunner.(*AntiProxyRunner).Stop()\n"
        "\t}\n"
        "\ts.Service.Stop()\n"
        "}\n"
        "func (s *Service) reloadProxyRunner(patch int) error {\n"
        "\trunner := NewAntiProxyRunner(patch)\n"
        "\terr := runner.Start()\n"
        "\tif err != nil { return err }\n"
        "\told := s.runner.Load()\n"
        "\ts.runner.Store(runner)\n"
        "\tif old != nil {\n"
        "\t\told.(*AntiProxyRunner).NoBattleStop()\n"
        "\t}\n"
        "\tgo func() {\n"
        "\t\t<-runner.Done()\n"
        "\t\ts.reloadProxyRunner(currentPatch)\n"
        "\t}()\n"
        "\treturn nil\n"
        "}\n",
        encoding='utf-8',
    )
    proxy.write_text(
        "package forward\n"
        "type AntiProxyLuaRunner struct {\n"
        "\tpatch   int\n\tcurrent int\n\texited  bool // if true, no battle will auto stop runner\n}\n"
        "func (r *AntiProxyLuaRunner) Stop() {\n"
        "\tlog.Infof(\"Stopping Runner[%d]\", r.idx)\n"
        "\tif err := r.closer.Close(); err != nil {\n"
        "\t\tlog.Errorf(\"Close Runner[%d] error %v\", r.idx, err)\n"
        "\t}\n"
        "\tif err := r.cmd.Wait(); err != nil {\n"
        "\t\tlog.Errorf(\"Stop Runner[%d] error %v\", r.idx, err)\n"
        "\t}\n"
        "}\n"
        "func (r *AntiProxyLuaRunner) StartBattle(record *scheme.CrossOnlineFightPlayRecord) (*ProxyRunnerResponse, error) {\n"
        "\tdata, err := util.MsgPack(record)\n"
        "\tif err != nil {\n\t\treturn nil, err\n\t}\n"
        "\tr.mu.Lock()\n\tdefer r.mu.Unlock()\n"
        "\treturn r.tolua(record.ID, \"start\", data)\n"
        "}\n"
        "func (r *AntiProxyLuaRunner) CloseBattle(id document.ID) (*ProxyRunnerResponse, error) {\n"
        "\treturn r.tolua(id, \"close\", []byte{})\n"
        "}\n"
        "func (r *AntiProxyLuaRunner) NoBattleStop() {\n"
        "\tr.mu.Lock()\n\tdefer r.mu.Unlock()\n\tr.exited = true\n"
        "\tif r.current == 0 {\n\t\tr.Stop()\n\t}\n"
        "}\n",
        encoding='utf-8',
    )
    rpcserver.write_text(
        "package nsq\n"
        "func getClientsNum(nsqdHTTP, topic, channel string) int {\n"
        "\tqueryUrl := fmt.Sprintf(\"http://%s/stats?topic=%s&channel=%s&format=json\", nsqdHTTP, url.QueryEscape(topic), url.QueryEscape(channel))\n"
        "\tstats := make(map[string]interface{})\n"
        "\ttopics := stats[\"topics\"].([]interface{})\n"
        "\t_ = topics\n"
        "\t_ = queryUrl\n"
        "\treturn 0\n"
        "}\n",
        encoding='utf-8',
    )
    subprocess.run(
        [sys.executable, str(root / 'scripts' / 'apply-runtime-hardening.py'), '--source-root', str(source)],
        check=True,
    )
    content = main.read_text(encoding='utf-8')
    assert 'tjgame/server_framework/tj/util' not in content
    assert '"fmt"' not in content
    assert '127.0.0.1:2112' in content
    assert 'NewAntiProxyRunner' not in forward.read_text(encoding='utf-8')
    assert 'NewAntiProxyLuaRunner' in forward.read_text(encoding='utf-8')
    proxy_content = proxy.read_text(encoding='utf-8')
    assert 'stopped bool' in proxy_content
    assert 'r.current++' in proxy_content
    assert 'stop := r.current == 0' in proxy_content
    rpc_content = rpcserver.read_text(encoding='utf-8')
    assert 'statsURL := url.URL{Scheme: "http", Host: nsqdHTTP, Path: "/stats"}' in rpc_content
    assert 'query.Set("topic", topic)' in rpc_content
    assert 'fmt.Sprintf("http://%s/stats' not in rpc_content
    assert 'topics, ok := stats["topics"].([]interface{})' in rpc_content
    assert 'if !ok {' in rpc_content
    subprocess.run(
        [sys.executable, str(root / 'scripts' / 'sanitize-kdjx-runtime-inputs.py'), '--runtime-root', str(source)],
        check=True,
    )
    rpc_content = rpcserver.read_text(encoding='utf-8')
    assert 'statsURL.String()' in rpc_content
    assert 'https://49.232.137.85/kdjx/feedback' not in rpc_content

economy_patch_path = root / 'scripts' / 'apply-sakura-economy-compatibility.py'
economy_spec = importlib.util.spec_from_file_location(
    'apply_sakura_economy_compatibility',
    economy_patch_path,
)
assert economy_spec is not None and economy_spec.loader is not None
economy_module = importlib.util.module_from_spec(economy_spec)
economy_spec.loader.exec_module(economy_module)
with tempfile.TemporaryDirectory(prefix='kdjx-economy-compatibility-') as temp:
    source = pathlib.Path(temp)
    role = source / 'release' / 'src' / 'game' / 'object' / 'game' / 'role.py'
    game = source / 'release' / 'src' / 'game' / 'object' / 'game' / '__init__.py'
    recharge_schema = source / 'gosrc' / 'tjgame' / 'document' / 'scheme' / 'Role.go'
    role.parent.mkdir(parents=True)
    recharge_schema.parent.mkdir(parents=True)
    role.write_text(
        '#!/usr/bin/python\n# -*- coding: utf-8 -*-\n'
        + economy_module.ROLE_CONSTANTS_ANCHOR
        + 'class ObjectRole(object):\n'
        + '\tdef init(self):\n'
        + economy_module.RECHARGE_INIT_ANCHOR
        + '\t\tself._inited = True\n\n'
        + '\t\tself.onGrowGuideTask(TargetDefs.Level, 0)\n'
        + '\t\treturn self\n\n'
        + '\tdef _initVIPLevel(self):\n'
        + '\t\tsumRMB = 0\n'
        + '\t\tfor rechargeID, data in self.recharges.iteritems():\n'
        + '\t\t\tif rechargeID not in csv.recharges:\n'
        + '\t\t\t\tcontinue\n'
        + '\t\t\tcfg = csv.recharges[rechargeID]\n'
        + '\t\t\tcnt = data.get("cnt", 0)\n'
        + economy_module.VIP_SUM_ANCHOR
        + '\t\tlevel = 0\n'
        + '\t\tfor index in csv.vip:\n'
        + '\t\t\tif csv.vip[index].upSum > sumRMB:\n'
        + '\t\t\t\tbreak\n'
        + '\t\t\tlevel = index - 1\n'
        + '\t\tself._vip_sum = sumRMB\n'
        + economy_module.VIP_LEVEL_ANCHOR
        + '\n'
        + '\tdef buyRecharge(self, rechargeID, orderID, **kwargs):\n'
        + '\t\trecharge = self.recharges.setdefault(rechargeID, {})\n'
        + '\t\torders = recharge.setdefault("orders", [])\n'
        + '\t\treset = recharge.get("reset", 0)\n'
        + '\t\tcnt = recharge.get("cnt", 0)\n'
        + '\t\tcfg = csv.recharges[rechargeID]\n'
        + '\t\tif cnt == 0 or reset > 0:\n'
        + '\t\t\trmb = cfg.rmb + cfg.firstPresent\n'
        + '\t\telse:\n'
        + '\t\t\trmb = cfg.rmb + cfg.present\n'
        + economy_module.RECHARGE_VALUE_ANCHOR
        + '\t\t\trecharge["reset"] = -abs(reset)\n'
        + '\t\t\trecharge["cnt"] = cnt + 1\n'
        + economy_module.RECHARGE_DONE_ANCHOR
        + '\t\tdone()\n'
        + '\t\tself.rmb += rmb\n'
        + '\t\tself._initVIPLevel()\n'
        + economy_module.RECHARGE_PROGRESS_ANCHOR
        + '\t\treturn rmb\n\n'
        + economy_module.ROLE_METHOD_ANCHOR
        + '\t\tpass\n',
        encoding='utf-8',
    )
    game.write_text(
        'class ObjectGame(object):\n'
        '\tdef init(self):\n'
        '\t\tself.role.init()\n'
        + economy_module.GAME_INIT_ANCHOR,
        encoding='utf-8',
    )
    recharge_schema.write_text(
        'package scheme\n\n' + economy_module.RECHARGE_SCHEMA_ANCHOR,
        encoding='utf-8',
    )
    economy_command = [
        sys.executable,
        str(economy_patch_path),
        '--source-root',
        str(source),
    ]
    subprocess.run(economy_command, check=True)
    subprocess.run(economy_command, check=True)
    role_content = role.read_text(encoding='utf-8')
    game_content = game.read_text(encoding='utf-8')
    recharge_schema_content = recharge_schema.read_text(encoding='utf-8')
    ast.parse(role_content, filename=str(role))
    ast.parse(game_content, filename=str(game))
    assert role_content.count('SakuraRechargeRMB = {') == 1
    assert role_content.count('def _applySakuraRechargeCompatibility(self):') == 1
    assert role_content.count(
        'def _applySakuraTrainerExperienceCompatibility(self):'
    ) == 1
    assert role_content.count('self._applySakuraRechargeCompatibility()') == 1
    assert 'self._applySakuraTrainerExperienceCompatibility()' not in role_content
    assert game_content.count(
        'self.role._applySakuraTrainerExperienceCompatibility()'
    ) == 1
    assert game_content.index('self.cards.init()') < game_content.index(
        'self.role._applySakuraTrainerExperienceCompatibility()'
    )
    assert recharge_schema_content.count('SakuraValueFixV1 bool') == 1
    assert recharge_schema_content.count(
        'codec:"sakura_value_fix_v1,omitempty" '
        'bson:"sakura_value_fix_v1,omitempty"'
    ) == 1
    assert 'self.vip_level = max(self.vip_level, level)' in role_content
    assert "recharge[SakuraRechargeFixMarker] = True" in role_content

    init_events = []
    game_namespace = {}
    exec(compile(game_content, str(game), 'exec'), game_namespace)

    class InitProbe(object):
        def __init__(self, name):
            self.name = name

        def init(self):
            init_events.append(self.name)

    class RoleInitProbe(InitProbe):
        def _applySakuraTrainerExperienceCompatibility(self):
            assert init_events == ['role', 'cards']
            init_events.append('trainer_exp')

    object_game = game_namespace['ObjectGame']()
    object_game.role = RoleInitProbe('role')
    object_game.cards = InitProbe('cards')
    object_game.society = InitProbe('society')
    object_game.init()
    assert init_events == ['role', 'cards', 'trainer_exp', 'society']

    class TestLogger(object):
        def info(self, *args):
            pass

        def warning(self, *args):
            pass

    namespace = {
        'logger': TestLogger(),
        'objectid2string': str,
    }
    exec(compile(role_content, str(role), 'exec'), namespace)
    class Python2Dict(dict):
        def iteritems(self):
            return self.items()

    namespace['SakuraRechargeRMB'] = Python2Dict(
        namespace['SakuraRechargeRMB']
    )
    recharge_configs = Python2Dict({
        3: type('RechargeConfig', (), {
            'rmb': 65,
            'firstPresent': 65,
            'present': 65,
            'validRechargeHuodong': False,
        })(),
        4: type('RechargeConfig', (), {
            'rmb': 33,
            'firstPresent': 33,
            'present': 33,
            'validRechargeHuodong': False,
        })(),
        5: type('RechargeConfig', (), {
            'rmb': 20,
            'firstPresent': 20,
            'present': 20,
            'validRechargeHuodong': False,
        })(),
        7: type('RechargeConfig', (), {
            'rmb': 6,
            'firstPresent': 6,
            'present': 6,
            'validRechargeHuodong': False,
        })(),
    })
    vip_configs = Python2Dict({
        1: type('VipConfig', (), {'upSum': 0})(),
        29: type('VipConfig', (), {'upSum': 900000})(),
        30: type('VipConfig', (), {'upSum': 1000000})(),
    })
    namespace['csv'] = type('TestCsv', (), {
        'recharges': recharge_configs,
        'vip': vip_configs,
    })()
    namespace['TestOrderID'] = 'test-order'
    object_role = namespace['ObjectRole']()
    object_role.id = '64b000000000000000000001'
    object_role.rmb = 187
    object_role.vip_level = 22
    object_role.recharges = Python2Dict({
        3: {'cnt': 144},
        4: {'cnt': 1},
        5: {'cnt': 1},
        7: {'cnt': 1},
    })
    object_role._applySakuraRechargeCompatibility()
    assert object_role.rmb == 920329
    assert all(
        recharge.get(namespace['SakuraRechargeFixMarker']) is True
        for recharge in object_role.recharges.values()
    )
    object_role._applySakuraRechargeCompatibility()
    assert object_role.rmb == 920329
    corrected_vip_sum = sum(
        recharge['cnt'] * namespace['SakuraRechargeRMB'][recharge_id]
        for recharge_id, recharge in object_role.recharges.items()
    )
    assert corrected_vip_sum == 938980
    object_role._initVIPLevel()
    assert object_role._vip_sum == 938980
    assert object_role.vip_level == 28

    object_role.recharges = Python2Dict({7: {'cnt': 1}})
    object_role._initVIPLevel()
    assert object_role.vip_level == 28
    object_role.recharges = Python2Dict({
        3: {
            'cnt': 144,
            namespace['SakuraRechargeFixMarker']: True,
        },
        4: {'cnt': 1, namespace['SakuraRechargeFixMarker']: True},
        5: {'cnt': 1, namespace['SakuraRechargeFixMarker']: True},
        7: {'cnt': 1, namespace['SakuraRechargeFixMarker']: True},
    })

    class TestDailyRecord(object):
        recharge_rmb_sum = 0

    class TestItems(object):
        def __init__(self):
            self.items = {400: 2109}

        def getItemCount(self, item_id):
            return self.items.get(item_id, 0)

        def costItems(self, values):
            for item_id, count in values.items():
                if self.items.get(item_id, 0) < count:
                    return False
            for item_id, count in values.items():
                left = self.items[item_id] - count
                if left:
                    self.items[item_id] = left
                else:
                    self.items.pop(item_id)
            return True

        def addItem(self, item_id, count):
            self.items[item_id] = self.items.get(item_id, 0) + count

    object_role.game = type('TestGame', (), {
        'items': TestItems(),
        'dailyRecord': TestDailyRecord(),
    })()
    before_recharge = object_role.rmb
    awarded = object_role.buyRecharge(
        3,
        'sakura-order-145',
        channel='sakura',
    )
    assert awarded == 6480
    assert object_role.rmb == before_recharge + 6480
    assert object_role.recharges[3]['cnt'] == 145
    assert object_role.recharges[3][namespace['SakuraRechargeFixMarker']] is True
    assert object_role.game.dailyRecord.recharge_rmb_sum == 6480
    object_role.exp = 500
    object_role._applySakuraTrainerExperienceCompatibility()
    assert object_role.exp == 2609
    assert object_role.game.items.getItemCount(400) == 0
    object_role._applySakuraTrainerExperienceCompatibility()
    assert object_role.exp == 2609

with tempfile.TemporaryDirectory(prefix='kdjx-role-data-compatibility-') as temp:
    source = pathlib.Path(temp)
    role = source / 'release' / 'src' / 'game' / 'object' / 'game' / 'role.py'
    session = source / 'release' / 'src' / 'game' / 'session.py'
    role.parent.mkdir(parents=True)
    session.parent.mkdir(parents=True, exist_ok=True)
    role.write_text(
        "class ObjectRole(object):\n"
        "\tdef onCardSkinRefresh(self, skinIDs):\n"
        "\t\trefreshAll = False\n"
        "\t\tmarkIDs = []\n"
        "\t\tfor skinID in skinIDs:\n"
        "\t\t\tcfg = csv.card_skin[skinID]\n"
        "\t\t\tif cfg.attrAddType == CardSkinDefs.sameMarkID:\n"
        "\t\t\t\tmarkIDs.append(cfg.markID)\n"
        "\tdef calCardSkinAttr(self, skinID):\n"
        "\t\tcfg = csv.card_skin[skinID]\n"
        "\t\tmarkID = cfg.markID if cfg.attrAddType == CardSkinDefs.sameMarkID else 0\n"
        "\tdef activeSkin(self, itemID):\n"
        "\t\tspecialArgsMap = csv.items[itemID].specialArgsMap\n"
        "\t\tskinID = specialArgsMap[\"skinID\"]\n"
        "\t\tdays = specialArgsMap[\"days\"] or 0\n",
        encoding='utf-8',
    )
    session.write_text(
        "class Session(object):\n"
        "\tdef refresh(self, skinsDeleted):\n"
        "\t\t\t\tfor skinID in skinsDeleted:\n"
        "\t\t\t\t\tcardMarkID = csv.card_skin[skinID].markID\n"
        "\t\t\t\t\tcards = game.cards.getCardsByMarkID(cardMarkID)\n",
        encoding='utf-8',
    )
    compatibility_command = [
        sys.executable,
        str(root / 'scripts' / 'apply-runtime-data-compatibility.py'),
        '--source-root',
        str(source),
    ]
    subprocess.run(compatibility_command, check=True)
    subprocess.run(compatibility_command, check=True)
    role_content = role.read_text(encoding='utf-8')
    session_content = session.read_text(encoding='utf-8')
    assert role_content.count('if cfg is None:') == 2
    assert 'missing from card_skin csv during init' in role_content
    assert 'missing from card_skin csv during refresh' in role_content
    assert 'ignored item %s with missing card skin %s' in role_content
    assert session_content.count('if cfg is None:') == 1
    assert 'missing from card_skin csv during expiry' in session_content
PY

grep -Fq 'location = /kdjx/servers {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /kdjx/version {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /kdjx/notice {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /kdjx/report {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /kdjx/word-check {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /kdjx/feedback {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /games/kdjx/support {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /games/kdjx/privacy {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location ^~ /games/kdjx/telemetry/ {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /novel-api/games/kdjx/sessions/verify {' "$root_dir/nginx/kdjx-login-locations.conf"
grep -Fq 'location = /novel-api/games/kdjx/sessions/verify/ {' "$root_dir/nginx/kdjx-login-locations.conf"
! grep -Fq '/internal/sakura/payments/verify' "$root_dir/nginx/kdjx-login-locations.conf"
! grep -Fq '/sso-ticket' "$root_dir/nginx/kdjx-login-locations.conf"
! grep -Fq '/games/kdjx/sso/exchange' "$root_dir/nginx/kdjx-login-locations.conf"
! grep -R -Fq 'anti-cheat-agent' "$root_dir/systemd" "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'command -v luajit' "$root_dir/systemd/kdjx-anti-cheat.service"
grep -Fq 'command -v luajit' "$root_dir/systemd/kdjx-online-fight-forward.service"
grep -Fq 'http://127.0.0.1:4161/ping' "$root_dir/systemd/kdjx-nsqlookupd.service"
grep -Fq 'http://127.0.0.1:4151/ping' "$root_dir/systemd/kdjx-nsqd.service"
grep -Fq -- '--retry-connrefused' "$root_dir/systemd/kdjx-nsqlookupd.service"
grep -Fq -- '--retry-connrefused' "$root_dir/systemd/kdjx-nsqd.service"
grep -Fq 'validate-runtime-env.py --env-file /etc/kdjx/runtime.env' "$root_dir/systemd/kdjx-login.service"
grep -Fq 'EnvironmentFile=-/etc/kdjx/gm.env' "$root_dir/systemd/kdjx-login.service"
for service_file in "$root_dir"/systemd/*.service; do
    if [[ "$service_file" != "$root_dir/systemd/kdjx-login.service" ]]; then
        ! grep -Fq '/etc/kdjx/gm.env' "$service_file"
    fi
done
grep -Fq 'runtime_env_validator' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'gm_env_validator' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'curl_options=(--connect-timeout 2 --max-time 5)' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'require_loopback_json_status 401 /internal/sakura/gm/deliveries' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'require_loopback_json_status 401 /internal/sakura/payments/verify' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'require_loopback_json_status 401 /internal/sakura/payments/fulfill' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'sakura-payment-rpc-gate-v1' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'Sakura offline payment channel cache is unavailable' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq "channel=channel or 'sakura')" \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'sakura-economy-compatibility-v1' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq '/kdjx/version?fake=true' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq "expected_app_version='2.1.'" "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq "expected_app_version+='0.0'" "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq '"patch_url":"https://novel.kxhub.xyz/games/kdjx/hot/"' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'install -d -m 0750 "$candidate_root/release/logs"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq -- '--gm-catalog <validated-kdjx-gm-item-catalog.json>' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'apply-sakura-gm-delivery.py' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'apply-sakura-payment-rpc.py' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'sakura-payment-rpc-gate-v1' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'apply-sakura-economy-compatibility.py' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'sakura-economy-compatibility-v1' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'apply-runtime-data-compatibility.py' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'validate-kdjx-gm-item-catalog.py' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'validate-kdjx-login-patches.py' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq -- '--items-lua "$anti_cheat_scripts/config/items.lua"' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq '"$candidate_root/kdjx-gm-item-catalog.json"' \
    "$root_dir/scripts/stage-kdjx-runtime.sh"
! grep -Fq 'KDJX_GM_' "$root_dir/templates/runtime.env.example"
grep -Fq 'KDJX_GM_HMAC_SECRET=' "$root_dir/templates/gm.env.example"
grep -Fq 'KDJX_GM_ITEM_CATALOG_FILE=/opt/kdjx/runtime/current/kdjx-gm-item-catalog.json' \
    "$root_dir/templates/gm.env.example"
grep -Fq 'def SakuraGMSendMail(' "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 'func (s *Service) SakuraGMSendMail(' \
    "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 's.Register(s, "SakuraGMSendMail")' \
    "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 'def ensureVisible(mail):' "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 'mailbox = copy.deepcopy(game.role.mailbox)' \
    "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq "raise Return('request_conflict')" "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 's.initSakuraGMDelivery()' "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq "attachs['role_exp']" \
    "$root_dir/scripts/apply-sakura-gm-delivery.py"
grep -Fq 'Sakura online GM mailbox persistence is unavailable' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'Sakura GM mailbox persistence gate is unavailable' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'def _applySakuraRechargeCompatibility(self):' \
    "$root_dir/scripts/apply-sakura-economy-compatibility.py"
grep -Fq 'def _applySakuraTrainerExperienceCompatibility(self):' \
    "$root_dir/scripts/apply-sakura-economy-compatibility.py"
grep -Fq 'self.vip_level = max(self.vip_level, level)' \
    "$root_dir/scripts/apply-sakura-economy-compatibility.py"
grep -Fq 'func (s *Service) VerifySakuraPayment(' \
    "$root_dir/scripts/apply-sakura-payment-rpc.py"
grep -Fq 'func (s *Service) PayForRecharge(' \
    "$root_dir/scripts/apply-sakura-payment-rpc.py"
grep -Fq 's.Register(s, "VerifySakuraPayment")' \
    "$root_dir/scripts/apply-sakura-payment-rpc.py"
grep -Fq 's.Register(s, "PayForRecharge")' \
    "$root_dir/scripts/apply-sakura-payment-rpc.py"
grep -Fq 'OFFLINE_REPLAY_REPLACEMENT' \
    "$root_dir/scripts/apply-sakura-payment-rpc.py"
grep -Fq 'Handle("/internal/sakura/gm/deliveries"' \
    "$root_dir/patches/sakura-gm/sakura_gm.go"
grep -Eq 'gmMailTemplate[[:space:]]+= 2' \
    "$root_dir/patches/sakura-gm/sakura_gm.go"
grep -Fq 'request.Quantity > item.MaxQuantity' \
    "$root_dir/patches/sakura-gm/sakuragm/handler.go"
grep -Fq 'request.ServerKey != "game.cn.1"' \
    "$root_dir/patches/sakura-gm/sakuragm/handler.go"
grep -Fq 'request.CatalogSHA256 != catalogSHA256' \
    "$root_dir/patches/sakura-gm/sakuragm/handler.go"
grep -Fq '[[ -d "$runtime_root/release/logs" && ! -L "$runtime_root/release/logs" ]]' "$root_dir/scripts/run-python-game.sh"
grep -Fq "created|exited|dead)" "$root_dir/scripts/run-python-game.sh"
grep -Fq 'docker rm -- "$container_name"' "$root_dir/scripts/run-python-game.sh"
grep -Fq 'game container is already %s' "$root_dir/scripts/run-python-game.sh"
! grep -Fq '"$candidate_root/$target/crossdata.json"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq '"$candidate_root/online_fight_forward"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'forward_patch_source="$source_root/release/online_fight_forward/cn_patch"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq '"$candidate_root/online-fight-forward/cn_patch"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq '"$candidate_root/online_fight_forward/cn_patch"' "$root_dir/scripts/stage-kdjx-runtime.sh"
grep -Fq 'cross_forward_patch="$runtime_root/online_fight_forward/cn_patch"' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'cmp --silent "$forward_patch" "$cross_forward_patch"' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'kdjx-game@1.service' "$root_dir/systemd/kdjx-runtime.target"
grep -Fq 'kdjx-game@1.service' "$root_dir/systemd/kdjx-login.service"
grep -Fq 'kdjx-game@1.service' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq "'game.cn.1'" "$root_dir/scripts/generate-runtime-config.py"
grep -Fq '28879' "$root_dir/scripts/generate-runtime-config.py"
grep -Fq 'for port in 2113 27159 4150 4160 4161 18080 16666; do' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'ss --udp --listening --numeric --no-header "sport = :$port"' \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq 'require_udp_listener 32888' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
! grep -Fq '28879' "$root_dir/scripts/healthcheck-kdjx-runtime.sh"
grep -Fq -- '-address=0.0.0.0:32888' \
    "$root_dir/systemd/kdjx-online-fight-forward.service"
grep -Fq -- '-metrics-address=127.0.0.1:2113' \
    "$root_dir/systemd/kdjx-online-fight-forward.service"
for topology_asset in \
    "$root_dir/scripts/generate-runtime-config.py" \
    "$root_dir/scripts/healthcheck-kdjx-runtime.sh" \
    "$root_dir/systemd/kdjx-runtime.target" \
    "$root_dir/systemd/kdjx-login.service" \
    "$root_dir/README.md"; do
    ! grep -Eq 'game\.cn\.2|kdjx-game@2|28878' "$topology_asset"
done
grep -Fq 'libsnappy-dev' "$root_dir/templates/legacy-python.Dockerfile"
for dependency in \
    'lz4==0.8.2' \
    'numpy==1.16.6' \
    'pycryptodome==3.9.9' \
    'python-snappy==0.5.4' \
    'requests==2.27.1' \
    'simplejson==3.17.6'; do
    grep -Fq "$dependency" "$root_dir/templates/legacy-python.Dockerfile"
done
grep -Fq 'lz4.uncompress(lz4.compress(data)) == data' \
    "$root_dir/templates/legacy-python.Dockerfile"
grep -Fq 'snappy, "StreamCompressor"' \
    "$root_dir/templates/legacy-python.Dockerfile"
grep -Fq 'AES.MODE_CBC' "$root_dir/templates/legacy-python.Dockerfile"
! grep -R --exclude='verify-deployment-assets.sh' -E '192\.168\.|123\.207\.|119\.28\.|http://47\.88\.26\.14/kdjx/patch' "$root_dir"
grep -Fq 'cd "$candidate_root/gosrc/tjgame/login"' "$root_dir/scripts/stage-kdjx-runtime.sh"

if command -v systemd-analyze >/dev/null 2>&1 \
    && [[ -x /opt/kdjx/runtime/current/bin/login_server ]]; then
    # systemd-analyze resolves absolute ExecStart paths. The source asset
    # check runs before staging creates those binaries; deployment verifies
    # the units again after the runtime symlink is switched.
    systemd-analyze verify "$root_dir"/systemd/*.service "$root_dir"/systemd/*.target
fi

printf 'KDJX deployment assets verified.\n'
