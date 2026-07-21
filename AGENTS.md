# Repository Instructions

- Do not sync fixes or changes to `E:\workSpace\novel_g`; treat it as a separate project.
- Keep unrelated changes in this workspace untouched.
- For every completed feature update or bug fix, run relevant verification, then create a focused Git commit containing only the related files and push it to the configured GitHub remote. Do not include unrelated existing changes in the commit.
- GitHub is only the source archive and CI target. Never use or re-enable a GitHub Actions workflow, webhook, or the retired automatic update workflow to deploy production changes.
- After verifying a backend or admin update, deploy it by connecting directly to the designated production server and run the documented health checks there.
- After verifying an Android app update, increment its version name and code, build and verify the signed APK, upload the immutable versioned APK directly to the download server, and replace `version.json` last. Do not publish APKs through GitHub workflows.
- Never commit or push secrets or private data: server connection keys, SSH keys, `.env` files, access tokens, passwords, API credentials, private certificates, user uploads, device bug reports, logs, or local release archives. Store production credentials only in the server environment; commit redacted `.env.example` placeholders when documentation is needed.
- Before every GitHub push, review staged files for sensitive data. If a secret or private artifact reaches Git history, remove it from all reachable history and rotate the affected credential before pushing again.
