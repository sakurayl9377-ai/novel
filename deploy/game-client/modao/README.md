# Modao Android client patch

This patch layer is intentionally kept separate from the 2 GB APK payload.

- `SakuraBridge.java` is the Java reference contract for the launch extras,
  HTTPS `/sakura/sso/exchange` validation, and payment result fields. The APK
  patch inlines the equivalent one-shot `takeSakuraExtra` reader in
  `AppActivity.smali`, so no new Java class is required at build time.
- `patch-client.mjs` applies asserted, one-match rewrites to the generated Cocos
  bundle. Sakura SSO never depends on the legacy account/password cache. Use
  `--skip-reconnect` when the reviewed GNet reconnect baseline is already
  present.
- `patch-hot-update.mjs` replaces the dead legacy updater with the managed
  HTTPS channel at `https://novel.kxhub.xyz/games/modao/hot/`. Manifest checks
  fail open after 10 seconds and an update with no progress fails open after
  120 seconds. `prepare-hot-update.mjs` restores the last successful update
  search path before Cocos loads the main bundle and rewrites the embedded
  manifests to the managed channel.
- `build-hot-update-release.mjs` packages the reviewed manifest asset set.
  Pass a monotonically increasing optional release version for later hot
  releases without changing the APK's embedded bootstrap version.
- `patch-managed-sso.mjs` makes the dedicated Android package fail closed on
  Sakura SSO. A missing, expired, or rejected session never falls back to the
  legacy registration UI. A standalone first launch shows one `樱花登录`
  button. It opens
  `sakura-novel://modao-auth/request?requestId=<32-128-char nonce>` without
  putting a ticket in the URI. The novel app explicitly returns the ticket to
  package `com.you91.fish.lucky` with action
  `com.you91.fish.lucky.SAKURA_SSO_CALLBACK` and the
  `sakura_sso_ticket`, `sakura_sso_exchange_url`,
  `sakura_sso_source`, and optional `sakura_sso_request_id` extras.
  A successful exchange persists only the game account, token expiry, and
  reviewed server data in game-private local storage. Later standalone starts
  restore that session and stop at server selection.
- `patch-sakura-payment-ui.mjs` preserves the original RMB amount and payment
  choices. Both choices are intercepted after order creation and handed to the
  novel app; only the novel app confirmation screen displays and deducts the
  authoritative Sakura coin amount at `10 Sakura coins = 1 CNY`. A confirmed
  `delivered`, `fulfilled`, or `success` return closes the active game payment
  panel; pending, cancelled, failed, and refunded returns keep it open.
- `patch-native.mjs` registers the explicit callback action, consumes callback
  extras once, creates authorization request IDs, and converts a missing novel
  app into a user-visible login failure instead of an Android crash.

The payment handoff is `sakura-novel://modao-payment/pay` with
`gameOrderId` and `productId` query fields. The novel app returns
`sakura_payment_order_id`, `sakura_payment_status`, and
`sakura_payment_balance` extras. The authoritative conversion is
`10 Sakura coins = 1 CNY`; the client calculates display text only and accepts
only the server-issued order URL. Order creation or app-launch failures show a
visible `支付服务暂不可用，请稍后重试` message.

The patch must be applied to a clean decoded client bundle. Every replacement
fails closed if the upstream bundle no longer matches the reviewed version.

## Verification

Run the self-contained hot-update and bridge tests, then point the managed SSO
test at the patched bundle that will be packaged:

```powershell
node test-hot-update.mjs
node test-sakura-bridge.mjs
node test-native-contract.mjs
node test-managed-sso.mjs D:\release\decoded\assets\assets\main\index.js
node test-sakura-payment-ui.mjs D:\release\decoded\assets\assets\main\index.js
node --check D:\release\decoded\assets\assets\main\index.js
```

Every rebuilt APK must use a version code greater than the currently published
game manifest. Verify zip alignment, all enabled APK signing schemes, the fixed
game signing certificate, package name, version code, and the embedded bundle
before generating the release manifest. Never commit an APK, signing key, key
password, decoded proprietary asset tree, or release archive.
