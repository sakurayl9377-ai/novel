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

Flutter 新版打包后先归档：

```powershell
flutter build apk --release
.\tool\archive_release.ps1
```

脚本会保留：

```text
build\release-archive\app-release-<version>+<code>.apk
build\release-archive\version-<version>+<code>.json
```

上传服务器时再把这次归档包复制成线上固定文件名：

```text
/var/www/yunpan/app3/app-release.apk
/var/www/yunpan/app3/version.json
```

替换前先备份服务器旧文件，不要删除旧归档包。
