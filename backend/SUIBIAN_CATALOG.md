# 随便看内容清单

随便看后端不抓取第三方网站。内容通过服务器管理的 JSON 清单装填，清单包含产品自己的标题、分类和每集 HLS 线路。

## 配置

本地文件优先：

```text
SUIBIAN_CATALOG_FILE=./data/suibian-catalog.json
```

如果本地文件不存在，可以配置自己的 HTTPS 清单接口：

```text
SUIBIAN_CATALOG_URL=https://catalog.example.com/suibian/catalog.json
SUIBIAN_CATALOG_TOKEN=<server-side bearer token>
```

Token 只保存在后端环境中。服务端禁止跟随重定向，且不包含任何 Cloudflare 绕过逻辑。

## Schema

参考 `suibian-catalog.example.json`。分类只接受 `comic` 或 `short`。每个有效内容至少要有一集，每集至少要有一条 HTTPS `.m3u8` 线路。

推荐的多线路格式：

```json
{
  "title": "第 1 集",
  "sources": [
    { "name": "主线路", "hlsUrl": "https://media.example.com/1.m3u8" },
    { "name": "备用线路", "hlsUrl": "https://backup.example.com/1.m3u8" }
  ]
}
```

为兼容旧清单，单线路也可以直接填写 `hlsUrl`。播放接口统一返回 `candidates`，后端不固定选择线路；Android 客户端可按首包延迟选择最快线路，并在播放失败时依次回退。

## 状态与错误

`GET /api/suibian/status` 返回配置模式、缓存条数、最近成功时间和脱敏后的最近错误。响应不会包含清单 URL、Bearer Token 或 HLS 地址。

远端接口的 403、5xx、超时及网络错误统一返回 HTTP 502。本地清单缺失且没有可用 HTTPS 接口时返回 HTTP 503。
