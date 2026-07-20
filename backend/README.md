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
后台管理（Vue 工作台）: http://127.0.0.1:3010/admin/
旧版后台（应急回退）: http://127.0.0.1:3010/admin/legacy/
API 前缀: http://127.0.0.1:3010/api
```

新版后台源码位于 `admin-ui/`。本地联调时分别启动后端与 Vite：

```bash
npm run dev
npm run admin:dev
```

Vite 开发地址为 `http://127.0.0.1:5174/`。提交前运行：

```bash
npm run admin:typecheck
npm run admin:test
npm run admin:build
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

升级地址固定为 `https://novel.kxhub.xyz/app3/version.json`。替换前先备份服务器旧文件，不要删除旧归档包。下载服务器只承载 APK 与更新清单，不能部署后端服务。

## 游戏单点登录

第三方游戏的登录、用户资料、樱花币同步与幂等账变协议见
[`docs/game-sso-api.md`](../docs/game-sso-api.md)。

## 后端直连发布

仓库不再保留 GitHub Actions 后端部署工作流。推送到 GitHub 只运行 CI 校验，不能触发生产服务器更新。

每次后端发布均在本地完成验证和管理端构建后，直接连接指定的后端生产服务器：

```bash
# 归档必须只包含 backend/，且排除 .env、data/、node_modules 和私钥文件。
sha256sum novel-backend-<revision>.tar.gz
scp novel-backend-<revision>.tar.gz <deploy-user>@<backend-host>:/tmp/novel-backend-<revision>.tar.gz
ssh <deploy-user>@<backend-host> \
  "sudo -n /usr/local/sbin/novel-backend-deploy \
  '/tmp/novel-backend-<revision>.tar.gz' '<revision>' '<sha256>'"
```

发布脚本会先验证归档、依赖、安全测试和数据库备份，再以 release 目录和原子符号链接切换服务；健康检查失败时自动回滚。部署后核验本机 `/health` 与公网管理端路径。

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
