# App UI Redesign Plan

## Generated Concept

- Image model: `gpt-image-2`
- Concept board: `E:\workSpace\pic\imagegen-preview-20260630-212920-01.png`
- Direction: modern Chinese content app for novels, manga, anime, comments, danmaku, chat, and membership growth.

## Product Direction

The current app should move from a basic utility layout to a content platform feel:

- Home becomes discovery first: search, tabs, ranked shelves, continue reading/watching, recommendations.
- Detail pages become content cards: cover, score, status, tags, independent review area, chapters/episodes.
- Player becomes video first: danmaku on the video surface, bottom controls, right-side settings in landscape.
- Comment pages become discussion surfaces: rating summary, hot/latest tabs, replies, user level badges.
- Profile becomes a member center: avatar, level effect, daily tasks, coin/points, privileges, shop, history.

## Profile UI Boards

- Main profile, daily rewards, edit profile: `E:\workSpace\novel\docs\profile-ui\imagegen-preview-20260630-232420-01.png`
- Member center, coin shop, account and space: `E:\workSpace\novel\docs\profile-ui\imagegen-preview-20260630-232656-01.png`
- Login, register, reset password: `E:\workSpace\novel\docs\profile-ui\imagegen-preview-20260630-232836-01.png`

## Visual System

- Keep Material 3, but replace the old color and spacing layer.
- Primary color: vivid blue for actions and active navigation.
- Secondary accents: warm orange/gold for score, level, reward, and membership moments.
- Background: neutral light gray, not pure white everywhere.
- Cards: 8px radius, subtle border, very soft shadow only for major modules.
- Typography: stronger hierarchy, fewer oversized titles, compact dense cards for content lists.
- Navigation: move from old `BottomNavigationBar` look to Material 3 `NavigationBar`.
- Empty states: use compact action surfaces, not large blank panels.

## Technical Selection

Stay with Flutter.

Reasons:

- Current app is already Flutter and has native-heavy features: video, TTS, file import, local storage, reader gestures.
- Rewriting in another framework would risk playback, TTS, reader, cache, and update flows.
- Flutter Material 3 can support the target design without replacing the stack.

Recommended additions:

- `go_router`: central route management after UI foundation stabilizes.
- `flutter_animate`: small motion language for tabs, cards, level effects, and player controls.
- `shimmer`: loading skeletons for shelves, comments, and history.
- Keep `provider` short term. Consider Riverpod later only if state complexity keeps growing.

Do not add a heavy UI kit. Build a local design system instead.

## Architecture Plan

Create a small UI foundation:

- `lib/design/app_tokens.dart`: colors, radius, spacing, elevation, text tokens.
- `lib/design/app_theme.dart`: Material 3 theme from tokens.
- `lib/design/widgets/`: reusable app bars, content cards, section headers, chips, skeletons, action bars.
- `lib/design/media/`: cover image, poster card, rank badge, progress badges.
- `lib/design/interaction/`: rating summary, comment item, danmaku controls, member level badge.

Then migrate page by page:

1. Main shell and bottom navigation.
2. Novel home/search and book detail.
3. Manga home/detail/reader chrome.
4. Anime home/detail/player chrome.
5. Comment/reply surfaces.
6. Profile/member center.
7. Settings/history/update pages.

## Refactor Rules

- Preserve existing services and models first.
- Do not change data contracts while redesigning UI unless a screen needs missing data.
- Replace repeated local styling with tokens.
- Avoid page-wide rewrites that also change business logic.
- Each phase must pass `flutter analyze` and `flutter test`.
- Release after each stable phase, not after one giant redesign branch.

## First Implementation Slice

Start with the foundation and shell:

- Add design tokens and new theme.
- Replace bottom navigation with `NavigationBar`.
- Create reusable `AppSectionHeader`, `AppContentCard`, `AppPosterCard`, `AppSkeleton`.
- Restyle `SearchScreen`, because it is the current first tab and sets the user's first impression.
