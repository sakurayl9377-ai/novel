# 小说 App 互动后端

这个后端给现有 Flutter 小说/漫画/动漫 App 提供独立互动能力，不接管原来的抓取逻辑。

## 功能

- 邮箱注册登录
- 图片验证码
- 邮箱验证码，按邮箱和 IP 做 60 秒防刷
- 小说/漫画/动漫评论和回复
- 视频弹幕 HTTP 拉取/发送与 WebSocket 实时推送
- 聊天室 WebSocket
- 举报
- 内置后台管理页 `/admin/`

## 本地启动

```powershell
cd backend
npm install
Copy-Item .env.example .env
npm run dev
```

默认地址：

```text
健康检查: http://127.0.0.1:3010/health
后台管理: http://127.0.0.1:3010/admin/
API 前缀: http://127.0.0.1:3010/api
```

默认管理员：

```text
邮箱: admin@admin.local
密码: admin123456
```

上线前必须修改 `.env` 里的 `TOKEN_SECRET`、`ADMIN_USERNAME`、`ADMIN_PASSWORD`。

## 邮箱验证码

注册流程：

```text
GET  /api/auth/captcha
POST /api/auth/email-code
POST /api/auth/register
POST /api/auth/login
```

`POST /api/auth/email-code` 需要带图片验证码：

```json
{
  "email": "user@example.com",
  "purpose": "register",
  "captchaId": "captcha-id",
  "captchaCode": "ABCD"
}
```

如果没有配置 SMTP，验证码会打印在服务日志里，方便本地联调。上线后配置：

```text
SMTP_HOST=
SMTP_PORT=465
SMTP_SECURE=true
SMTP_USER=
SMTP_PASS=
SMTP_FROM="Novel App <no-reply@example.com>"
```

## 主要接口

所有写入接口使用：

```text
Authorization: Bearer <token>
```

评论：

```text
GET  /api/comments?targetType=novel&targetId=<novelId>
POST /api/comments
GET  /api/comments/:id/replies
POST /api/comments/:id/like
```

弹幕：

```text
GET  /api/danmaku?videoId=<videoId>&fromMs=0&toMs=600000
POST /api/danmaku
WS   /ws/danmaku?videoId=<videoId>
```

聊天室：

```text
WS /ws/chat?token=<token>&roomId=global
```

房间建议：

```text
global
novel:<novelId>
manga:<mangaId>
anime:<animeId>
```

## 服务器部署建议

服务器原来的云盘项目已经占用 `/api` 时，把 `.env` 改成：

```text
PORT=3010
API_PREFIX=/novel-api
ADMIN_PATH=/novel-admin
WS_CHAT_PATH=/novel-ws/chat
WS_DANMAKU_PATH=/novel-ws/danmaku
```

Nginx 增加反代：

```nginx
location /novel-api/ {
  proxy_pass http://127.0.0.1:3010/novel-api/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}

location /novel-admin/ {
  proxy_pass http://127.0.0.1:3010/novel-admin/;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location /novel-ws/ {
  proxy_pass http://127.0.0.1:3010/novel-ws/;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## 发版不覆盖旧包

Flutter 新版先用受控脚本做干净构建、签名/版本、ABI 和体积校验，再归档：

```powershell
.\tool\build_android_release.ps1
.\tool\archive_release.ps1 -Notes @("本次更新说明")
```

脚本会保留：

```text
build\release-archive\app-release-<version>+<code>.apk
build\release-archive\version-<version>+<code>.json
build\release-archive\app-release.apk
build\release-archive\version.json
```

上传服务器时再把这次归档包复制成线上固定文件名：

```text
/var/www/novel-download/app3/app-release-<version>+<code>.apk
/var/www/novel-download/app3/version.json
```

Always upload and verify the versioned APK first, then replace `version.json`
last. Versioned APK names are immutable so an edge cache can never pair an old
APK with a new manifest checksum.

升级地址固定为 `https://novel.kxhub.xyz/app3/version.json`。替换前先备份服务器旧文件，不要删除旧归档包。

## 后端自动部署

仓库内置 `.github/workflows/deploy-backend.yml`。推送到 `main` 且
`backend/**` 有变化时，工作流会先运行安全测试，再通过 SSH 部署后端。

服务器首次接入时，以 root 身份运行：

```bash
cd /opt/novel-interaction-backend
sudo bash ./scripts/bootstrap-production-deploy.sh "ssh-ed25519 <GitHub Actions 部署公钥>"
```

接入脚本会以运行服务的账号定位 Node.js/npm，要求 Node.js 24 或更高版本，
并在 Ubuntu 上缺少 `sqlite3` 时自动安装。非标准 Node.js 安装路径可通过
`NOVEL_NODE_BIN` 和 `NOVEL_NPM_BIN` 显式传入。
脚本还会锁定 `novel-deploy` 的密码，并安装仅允许公钥认证的 SSH `Match`
配置；安装前后都会验证 sshd 配置，失败时恢复原配置。

GitHub `production` 环境需要配置以下 Secrets：

```text
DEPLOY_HOST       服务器地址
DEPLOY_PORT       SSH 端口，通常为 22
DEPLOY_USER       novel-deploy
DEPLOY_SSH_KEY    对应的部署私钥
DEPLOY_HOST_KEY   ssh-keyscan 返回的完整 known_hosts 行
```

首次部署会把服务器上的 `.env` 和 `data/` 移到
`/opt/novel-interaction-shared`，后续使用 release 目录和原子符号链接切换，
保留最近 6 个 release，并在健康检查失败时自动切回上一版本。
部署前会通过 SQLite online backup 保留最近 10 份数据库备份。数据库迁移
必须保持向后兼容，代码回滚不会反向修改数据库结构。

服务器环境只读审计：

```bash
sudo bash ./scripts/audit-production.sh
```

## 代理后台

管理后台的“代理管理”页面通过 root-owned helper 控制 Mihomo，不允许 Node.js
直接修改系统配置或执行任意命令。订阅地址只接受 HTTPS，保存后不会回传到浏览器；
定时更新会固定已验证的公网 IP，并对每次跳转重新校验，拒绝私网、回环、链路本地
和 CGNAT 地址。服务器需要已有 `mihomo.service`、本地控制器以及
`mihomo-subscription-update.service` / timer。
