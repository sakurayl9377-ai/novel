# Vendored libmpv Android binaries

- Upstream package: `media_kit_libs_android_video 1.3.8`
- Upstream binary release: `media-kit/libmpv-android-video-build v1.1.7`
- Source commit: `fe8c3ac1a91c09aa6fb1deccbc833f1bafa54768`
- Flavor: `default`
- Original release URL: `https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7`

The files are kept in-repository so Android builds never download executable
artifacts. The Gradle verification task checks size, upstream MD5 and SHA-256
before every build.

| File | Bytes | MD5 | SHA-256 |
| --- | ---: | --- | --- |
| `default-arm64-v8a.jar` | 5729978 | `83df25b61193af8fa815e373143ac9af` | `4363dfa5d3d415b91c1f16f6fb90c3fe59a77dfd3f9b824d2b24b492d6b09df9` |
| `default-armeabi-v7a.jar` | 5499353 | `22e21526fefc0a2b8f17adbec9f57590` | `8ead114fc5a43348d89dc0eb8f41823e549b15115c29f73ee26973f973620995` |
| `default-x86_64.jar` | 6516632 | `6fa26bf0459b11f1c0b0dbc29e5b940d` | `90268cd15f0766e07fb8e427388c621161177c9eb343c544f327bd63232bb236` |

The arm64 file was downloaded directly from the GitHub release. When the
connection to GitHub release storage repeatedly reset, the remaining files
were fetched through a transport proxy and accepted only after their byte
length and upstream-published MD5 matched. SHA-256 values above were computed
locally and are enforced by Gradle.
