#!/usr/bin/env python3
import json
from pathlib import Path
import pwd
import re
import subprocess


KEY_TYPES = (
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-",
    "sk-ssh-ed25519",
    "sk-ecdsa-sha2-",
)
TEMP_PATTERN = re.compile(r"(?:^|[-_])(temp|temporary)(?:[-_]|$)", re.IGNORECASE)


def fingerprint(key_type, key_data, comment):
    canonical = f"{key_type} {key_data} {comment}".strip() + "\n"
    result = subprocess.run(
        ["ssh-keygen", "-lf", "/dev/stdin"],
        input=canonical,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return "invalid"
    parts = result.stdout.strip().split()
    return parts[1] if len(parts) > 1 else "unknown"


def parse_line(raw):
    parts = raw.strip().split()
    key_index = next(
        (index for index, part in enumerate(parts) if part.startswith(KEY_TYPES)),
        -1,
    )
    if key_index < 0 or key_index + 1 >= len(parts):
        return None
    key_type = parts[key_index]
    key_data = parts[key_index + 1]
    comment = " ".join(parts[key_index + 2 :])
    return {
        "fingerprint": fingerprint(key_type, key_data, comment),
        "type": key_type,
        "comment": comment,
        "options": " ".join(parts[:key_index]),
        "temporary": bool(TEMP_PATTERN.search(comment)),
    }


def interactive_users():
    for user in pwd.getpwall():
        if user.pw_uid != 0 and not (1000 <= user.pw_uid < 65534):
            continue
        if user.pw_shell.endswith(("nologin", "false")):
            continue
        yield user


def main():
    records = []
    for user in interactive_users():
        home = Path(user.pw_dir)
        for path in (home / ".ssh" / "authorized_keys", home / ".ssh" / "authorized_keys2"):
            if not path.is_file():
                continue
            for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                parsed = parse_line(raw)
                if parsed is None:
                    continue
                records.append(
                    {
                        "user": user.pw_name,
                        "file": str(path),
                        "line": line_number,
                        **parsed,
                    }
                )
    print(json.dumps(records, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
