# NEFORUM design guide

NEFORUM should feel calm, editorial and confident: flat surfaces separated by
hairline borders, generous whitespace, one vivid accent, and the signature
gradient reserved for the single most important action on screen.

Everything below exists as code in `apps/neforum_app/lib/theme` and
`apps/neforum_app/lib/widgets`. Use those, never raw values.

## Brand colors

NEFORUM is purple **#7D00FF** and yellow **#FFFF00** (`Brand.purple`,
`Brand.yellow`).

- **Purple carries the brand**: the logo tile (`Brand.markGradient`, fixed
  whatever accent the user picks), the default accent, primary buttons
  (`accentFill`, white text passes WCAG AA), focus rings and links. On dark
  backgrounds, text and icons use the lighter `accent` (#9D4DFF) for contrast.
- **Yellow is the spark**: the logo (a yellow diamond on the purple tile: a
  solid roof breaking into bars, the message in a window at its heart; see
  `lib/brand/mark_geometry.dart`), the current section and the "New post"
  button on the navigation chrome, badges, and the tab on text cards. Use `highlight` as a fill with `onHighlight` (ink) text on it.
  **Never** use yellow as text, or as the only cue, on light surfaces: it has
  no contrast there.
- **Navigation chrome** (sidebar, rail, phone bottom bar) is deep purple in
  both themes by default (`chrome`, `chromeRaised`, `onChrome`, `onChromeMuted`).
  Settings > Appearance > Navigation bar can make it match the theme (the
  page's surfaces with a `chromeBorder` hairline, the accent instead of
  yellow for the current section) or the accent color. Mark the current
  section with `chromeAccent`/`onChromeAccent` (fills) and `chromeSelected`
  (sidebar icon and bar), never with `highlight` directly.
  `PrimaryAction(onChrome: true)` and `NeforumWordmark(onChrome: true)` are the
  variants for it.
- Neutrals carry a faint purple cast in both themes; semantic colors
  (success, warning, danger, info) stay as they are.

## Tokens

| Token | Where |
|---|---|
| `context.nf` | All semantic colors (`bg`, `surface`, `surfaceRaised`, `surfaceSunken`, `surfaceHover`, `border`, `borderStrong`, `text`, `textMuted`, `textFaint`, `accent`, `accentFill`, `accentSoft`, `highlight`/`onHighlight`, `chrome`/`chromeRaised`/`onChrome`/`onChromeMuted`/`chromeBorder`/`chromeAccent`/`onChromeAccent`/`chromeSelected`/`chromeActionGradient`, `success/warning/danger/info` and their `*Soft` backgrounds, `brandGradient`, `elevation1/2`, `glow()`) |
| `Space.*` | 4-pt spacing scale: `xxs 2, xs 4, sm 8, md 12, lg 16, xl 20, xxl 24, x3 32, x4 40, x5 48, x6 64` |
| `Radii.*` | `rXs 6, rSm 10, rMd 14, rLg 20, rXl 28, rPill`; all 0 with the square corner style (`Radii.square`, set by `buildTheme`). They are getters, never `const`. For other sizes use `Radii.circular(r)`, `Radii.corner(r)`, `Radii.circleShape`, `Radii.circleBorder`, `Radii.stadium`. Generated images (text cards, captions) keep fixed radii |
| `Motion.*` | `fast 140ms, medium 240ms, slow 420ms`, curves `standard`, `emphasized`, `spring` |
| `Breakpoints` | `compact < 720` (phone, bottom bar), `expanded ≥ 1180` (sidebar, side-by-side panes), `readable 760` max width for forms |
| `context.text` | Text theme. Display/headline/titleLarge use Bricolage Grotesque; everything else Inter |
| `monoStyle(context)` | JetBrains Mono with tabular figures: counters, tokens, URLs, codes |

Rules:

- Never hard-code a `Color(...)` in a screen. Brand colors come from
  `brandFor(platformId)`; everything else from `context.nf`.
- Never use `Colors.grey`, `Colors.black54` etc. Use `textMuted`/`textFaint`.
- Cards are `NfCard` (surface + 1px `border`, `rLg`). Wells (text areas,
  trays, code) are `NfWell` (`surfaceSunken`). No Material elevation shadows
  on cards; `NfCard(elevated: true)` only for floating things.
- One `PrimaryAction` (gradient) per screen at most. Secondary actions are
  `OutlinedButton`, `PillButton`, `TextButton` or `ToolButton`.
- Status is always a `StatusPill` with a `Tone` (see `postStatusStyle`,
  `targetStatusStyle`, `TierBadge`).
- Platform identity is always `PlatformTile` / `PlatformGlyph` /
  `AccountAvatar` / `PlatformStack`.
- Page structure: `PageBody(children: [PageHeader(...), ...sections])`.
  Section titles: `SectionHeader`. Empty lists: `EmptyState`.
  Toasts: `showToast`. Destructive confirmation: `confirmDialog`.
- Hover states on every clickable thing on desktop (`NfCard(onTap:)`,
  `ToolButton`, themed buttons already do this). Cursor `click`.
- Animate state changes with `AnimatedSwitcher`/`AnimatedContainer` using
  `Motion` durations. No animation longer than `Motion.slow`. Pass them
  through `context.motion(Motion.fast)`: with the system's reduce motion
  setting (`context.reduceMotion`) they become instant, and decorative
  motion (press shrink, looping marks) does not run at all.
- Colors: pick an existing token; `ColorWheel(color:, onChanged:)`
  (`lib/widgets/color_wheel.dart`) when the user picks a color themselves.
- Background picture (Settings > Appearance > Background): pages leave
  their background transparent when `BackdropScope.activeOf(context)`;
  cards keep their surface. The scrim keeps `text` and `textMuted`
  readable, so other text colors right on the page (an accent eyebrow) go
  through `legibleOverBackdrop`.
- High contrast (the system setting) swaps in `NfColors.withHighContrast()`
  by itself; use the tokens and it follows.

## Layout

- Phone (`context.isCompact`): single column, 16px gutters, sticky bottom
  action bar where a screen has a primary action, sheets instead of dialogs.
- Medium: rail navigation, 24px gutters, two columns only where content is
  naturally paired.
- Expanded (`context.isExpanded`): sidebar, 40px gutters, side-by-side panes
  (composer left, previews right), max content width 1240.
- Text never runs wider than ~75 characters; forms max `Breakpoints.readable`.
- Must work at 360×640 with no horizontal overflow and at 2560 wide without
  looking empty.

## Voice

Plain, friendly, short. Say what happens: "Posts automatically", "You tap
Post in Instagram", "Uses your own API keys". Avoid jargon (no "OAuth",
"BYOK", "endpoint" in primary UI; it can appear in the developer setup
guides). Numbers with units: "37 of 500 this month".

## The three ways to post

Every account shows how it publishes, using `TierBadge`:

- **Auto** (green, `openApi`): open API, nothing to pay, no review.
- **Your keys** (blue, `byokApi`): official API with a developer app the
  user creates; subject to quota (show `QuotaMeter`).
- **Hand-off** (amber, `handoff`): NEFORUM prepares everything, the user
  taps Post in the platform's own app. Works with any personal account.
