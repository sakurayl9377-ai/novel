# audio_service Android compatibility patch

This directory replaces only `AudioService.java` from `audio_service 0.18.18`.
The replacement keeps the upstream implementation intact except that
`MediaStyle.setShowActionsInCompactView(...)` is also called on Android 13+.

The media session also advertises legacy media-button/transport flags and
mirrors every visible native control into `PlaybackState.actions`. OriginOS 6
uses both signals when deciding whether previous/play/next slots are allowed.

OriginOS 6 can display the media metadata card while omitting every transport
button when the compact indices are not explicitly supplied. AOSP Android 13+
continues to derive its slots from `PlaybackState`, so the legacy MediaStyle
hint is harmless there.

When upgrading `audio_service`, rebase this file on the new upstream version
and update the pinned dependency in `pubspec.yaml`.

The copied upstream source remains licensed under the MIT License included in
`LICENSE.audio_service`.
