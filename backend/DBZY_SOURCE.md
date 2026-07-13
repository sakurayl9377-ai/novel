# 随便看 dbm3u8 采集源

后端使用豆瓣资源官方 MacCMS `dbm3u8` JSON 接口装填随便看内容。Android 客户端只访问本项目的 `/api/suibian/*`，不得直接连接采集接口。

## 同步与安全边界

- 增量同步使用 `ac=detail&h=<hours>&pg=<page>`，并限制单次最大页数。
- 分类页使用 `ac=detail&t=<type_id>&pg=<page>` 按需预热。
- 详情使用 `ac=detail&ids=<vod_id>`，播放字段按 MacCMS 的 `$$$`（线路）、`#`（剧集）、`$`（标题/地址）解析。
- 只向 App 输出 HTTPS `.m3u8`，HTTP 图片地址会规范化为 HTTPS。
- 数据缓存在服务端 `data/dbzy-cache.json`，搜索只查询这份自有缓存，不把用户关键词发送给上游。
- 服务端默认每 30 分钟后台增量同步一次；失败会指数退避，用户无需手动触发采集。
- Novel 统一后台的“随便看视频”页面可查看缓存、剧集、脱敏线路域名、同步状态，并执行隐藏/恢复覆盖；人工操作不会修改上游缓存。
- 分类展示由服务端策略控制，支持始终展示、始终隐藏和按时区每日时段展示（含跨午夜）。伦理片分类 `34` 默认仅在 `Asia/Hong_Kong` 00:00–06:00 展示并标记年龄限制。
- 上游访问有串行限速、超时、响应体大小限制和缓存 TTL；缓存文件不进入 Git。
- 伦理片（34）、新闻资讯（35）和体育赛事（36）默认隐藏。短剧使用 37 与子分类 43–49。
- 原有 `SUIBIAN_CATALOG_*` 自有清单继续作为 AI 漫剧补充源，不影响原有账号、评论、收藏和历史表。

## App API

- `GET /api/suibian/categories`
- `GET /api/suibian/movies/home`
- `GET /api/suibian/movies?categoryId=1&page=1&pageSize=20`
- `GET /api/suibian/movies/:id`
- `GET /api/suibian/movies/:id/episodes/:episodeIndex/playback`
- `GET /api/suibian/search?q=关键词`
- `GET /api/suibian/shorts/feed?categoryId=37&pageSize=12`
- `GET /api/suibian/shorts/:id`
- `GET /api/suibian/shorts/:id/episodes/:episodeIndex/playback`

详情 ID 使用 `dbzy:<vod_id>`，播放接口统一返回：

```json
{
  "index": 0,
  "title": "第1集",
  "candidates": [
    { "name": "dbm3u8", "hlsUrl": "https://media.example/1.m3u8" }
  ]
}
```

客户端可对 `candidates` 做首包测速并在播放失败时切换线路。
