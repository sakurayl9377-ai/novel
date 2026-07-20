# Repository Instructions

- Do not sync fixes or changes to `E:\workSpace\novel_g`; treat it as a separate project.
- Keep unrelated changes in this workspace untouched.
- For every completed feature update or bug fix, run relevant verification, then create a focused Git commit containing only the related files and push it to the configured GitHub remote. Do not include unrelated existing changes in the commit.
- Do not use or trigger GitHub Actions, CI/CD, or any automatic update workflow for deployment. After pushing a completed runtime change, deploy the affected backend directly to the production server over the existing controlled SSH release path.
- When a completed task changes the Flutter app, build and verify the signed release APK, upload the immutable versioned APK directly to the download server, verify its checksum, and replace the download manifest only after the APK is in place. Do not republish backend or APK artifacts for documentation-only or analysis-only tasks.
- Never commit or push secrets or private data: server connection keys, SSH keys, `.env` files, access tokens, passwords, API credentials, private certificates, user uploads, device bug reports, logs, or local release archives. Store production credentials only in the server environment; commit redacted `.env.example` placeholders when documentation is needed.
- Before every GitHub push, review staged files for sensitive data. If a secret or private artifact reaches Git history, remove it from all reachable history and rotate the affected credential before pushing again.
