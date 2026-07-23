# Modao Android client patch

This patch layer is intentionally kept separate from the 2 GB APK payload.

- `SakuraBridge.java` is the Java reference contract for the launch extras,
  HTTPS `/sakura/sso/exchange` validation, and payment result fields. The APK
  patch inlines the equivalent one-shot `takeSakuraExtra` reader in
  `AppActivity.smali`, so no new Java class is required at build time.
- `patch-client.mjs` applies asserted, one-match rewrites to the generated Cocos
  bundle. Sakura SSO uses the ticket supplied by the novel app; it does not
  depend on the legacy account/password cache. Use `--skip-reconnect` when the
  reviewed GNet reconnect baseline is already present.
- `patch-hot-update.mjs` disables the legacy Cocos hot-update check whose
  original HTTP endpoint is no longer reachable. The 2 GB APK already contains
  the complete reviewed resource set, so startup proceeds directly to login
  and game updates are delivered as a new signed APK. The script is also
  included by `patch-client.mjs` for clean rebuilds.
- `patch-managed-sso.mjs` makes the dedicated Android package fail closed on
  Sakura SSO. A missing, expired, or rejected ticket never falls back to the
  legacy registration UI. Successful SSO stops at server selection and waits
  for the player to tap Enter.

The payment handoff is `sakura-novel://modao-payment/pay` with
`gameOrderId` and `productId` query fields. The novel app returns
`sakura_payment_order_id`, `sakura_payment_status`, and
`sakura_payment_balance` extras. The authoritative conversion is
`10 Sakura coins = 1 CNY`; the client never calculates a price and accepts
only the server-issued order URL.

The patch must be applied to a clean decoded client bundle. Every replacement
fails closed if the upstream bundle no longer matches the reviewed version.

## Verification

Run the self-contained hot-update and bridge tests, then point the managed SSO
test at the patched bundle that will be packaged:

```powershell
node test-hot-update.mjs
node test-sakura-bridge.mjs
node test-managed-sso.mjs D:\release\decoded\assets\assets\main\index.js
node --check D:\release\decoded\assets\assets\main\index.js
```

Every rebuilt APK must use a version code greater than the currently published
game manifest. Verify zip alignment, all enabled APK signing schemes, the fixed
game signing certificate, package name, version code, and the embedded bundle
before generating the release manifest. Never commit an APK, signing key, key
password, decoded proprietary asset tree, or release archive.
