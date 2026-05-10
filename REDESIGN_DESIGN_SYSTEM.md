# FoodieAI iOS — Design System v2 (Premium Redesign)

This document supersedes `DESIGN_SYSTEM.md` v1 (the literal port of the web design). Where this document conflicts with the older one, this version wins.

The redesign is grounded in patterns I extracted from studying:
- Apple Human Interface Guidelines (iOS 17+)
- Calm — audio-first storytelling, low decision fatigue
- Headspace — playful illustration restrained, simple card navigation
- Balance — daily check-in personalization, calm pacing
- Waterllama — quick logging, smart reminders, playful character system without shame
- Gentler Streak — gentle nudges, recovery framing, Apple Design Award winner
- Ahead — bite-size lessons, science-based microcopy
- Noom — color-coded logging without shame, progressive disclosure

Brand DNA preserved: lime `#B8CA38` (used sparingly now, as accent), M PLUS Rounded 1c (used for hero numbers and big titles only), Nunito (used for everything else), the celebrity coach concept (reframed editorially).

---

## Twelve principles

These are the rules. When in doubt, return to them.

### 1. Quiet by default, expressive on action
The brand lime should appear three times per screen at most. Most surfaces are warm off-white (`#FAFAF6`) with rich black ink. Lime is reserved for: primary CTAs, active states, key data emphasis, success moments. The previous design used lime as ambient color (cards, panels, headers); this redesign uses it as accent.

### 2. One hero metric per screen
Each screen has one number that dominates. Result screen: calorie count at 88pt. Tracker: today's total in a progress ring at 56pt. Other data is secondary, stepped down sharply (chip text at 20pt, body at 16pt). The previous design rendered all macros at the same weight — that flatness erases hierarchy.

### 3. Photography first
The user took a beautiful photo. Honor it. On the result screen, the photo gets a 4:3 hero treatment with rounded corners and a small floating coach badge. On meal cards, the photo is a 56×56 thumbnail to the left of the text — visual primacy, not decoration.

### 4. Generous breathing room
Vertical rhythm uses larger gaps than the previous design. Section-to-section: 48pt. Block-to-block: 24pt. Inside cards: 16pt. The previous design used 16pt as the default — too dense for a premium feel.

### 5. The bottom is home base
Primary actions live in the thumb-reach zone (bottom 1/3 of screen). The "Take a photo" button on Capture, the "Save" button on Result — both pinned near the bottom. Data lives at the top where the eye lands first.

### 6. Editorial typography for emotional content
The celebrity coach quote is treated as a magazine pull-quote: large open-quote glyph at 64pt in lime, italic body, attribution rule + name. Not a speech bubble (web idiom). This makes the quote feel considered rather than chat-bubble cute.

### 7. Progressive disclosure
The result screen shows hero number + macros + photo + quote immediately. The three analysis sections (nutrients/benefits/drawbacks) are collapsed accordions by default — tap to expand. The user gets the headline first, the deep data on demand. The previous design dumped all three panels open with full typewriter — beautiful once, exhausting on revisit.

### 8. Numbers earn their size
Tabular numerals (Nunito's `.monospacedDigit()` modifier) on every data display so digits don't dance when totals update. Hero numbers get the most expensive type: M PLUS Rounded 1c at 88pt+ with `-3` letter-spacing for tightness. The kerning is subtle and considered, not decorative.

### 9. Motion serves hierarchy, not decoration
Default motion is fast (0.25s) and quiet. Only the moments that matter get expressive motion: the calorie count-up on result screen reveal (0.8s ease-out), the save success choreography (1.2s spring with confetti-free expansion), photo entrance (0.5s scale-in). The previous design animated everything — bouncing badges, perpetual motion on totals — which makes the eye tired.

### 10. Material depth, not flat web cards
Cards use white surfaces over the warm canvas with subtle 6pt shadows at 5% opacity. Some surfaces use `.ultraThinMaterial` for floating affordances (the coach badge over the photo, the segmented control). The previous design used solid color blocks — reads as web Bootstrap.

### 11. Iconography as ink, not illustration
SF Symbols at appropriate weights, sized 20pt for inline, 28pt for accent, 44pt for hero icons. Custom SVG icons (the existing nutrients/benefits/drawbacks marks) are kept but reduced to small monogram badges (28×28 circles with single letters) inside accordion rows. The full custom illustrations belong on the original analyze screen only — overusing them flattens hierarchy.

### 12. Habit reinforcement without shame
The progress ring on Tracker shows progress toward goal — never red badges, never "you failed." If the user logged zero meals, the ring is empty but the messaging is gentle ("Ready when you are"). Streak badges are absent. This matches Gentler Streak's recovery-first framing and the consistent finding that shame-driven UX kills retention.

---

## Color system

### Canvas & surfaces
| Token | Hex | Use |
|---|---|---|
| `bg-canvas` | `#FAFAF6` | App background. Slightly warmer than pure white. |
| `bg-surface` | `#FFFFFF` | Cards, sheets, dialogs. |
| `bg-surface-soft` | `#F4F2EC` | Subtle alt surface (segmented control track). |
| `border-hairline` | `#ECEAE2` | 1pt borders on cards. Avoid heavier borders. |

### Ink (text)
| Token | Hex | Use |
|---|---|---|
| `ink` | `#181715` | Primary text. Warm rich black, not pure black. |
| `ink-mute` | `#6B6862` | Secondary text, captions. |
| `ink-light` | `#A8A59E` | Tertiary/disabled, very small labels. |

### Brand
| Token | Hex | Use |
|---|---|---|
| `brand` | `#B8CA38` | Primary accent. CTAs, active states, key emphasis. **Never use as background.** |
| `brand-deep` | `#4A5713` | High-contrast text on brand-soft surfaces. |
| `brand-soft` | `#F4F8DD` | Tinted surfaces only when the lime context matters (hero icon container, badge). |

### Semantic accents
| Token | Hex | Use |
|---|---|---|
| `accent-warm` | `#E27B2C` | Sugar progress bar, energy moments, warning states. |
| `accent-cool` | `#5B7F8F` | Protein progress bar, secondary info. |
| `success` | `#5C8333` | Save success, positive deltas. |
| `error` | `#C83E3E` | Error states. Used sparingly. |

### Category palette (replaces the old panelBenefits/panelDrawbacks)
The old `#ADD8E6` blue and `#A9A9A9` gray panels are dropped. Replaced with monogram-badge tints:
| Token | Hex | Use |
|---|---|---|
| `cat-nutrients` | `#F4F8DD` (text `#4A5713`) | Nutrients category badge fill. |
| `cat-benefits` | `#DFEBF1` (text `#3A5663`) | Benefits category badge fill. |
| `cat-drawbacks` | `#FBE7D9` (text `#A04A1C`) | Drawbacks category badge fill. |

### Retired colors
Drop entirely from `Assets.xcassets`:
- `panelBenefits` (#ADD8E6) — blue panels read as Bootstrap.
- `panelDrawbacks` (#A9A9A9) — gray feels punitive in a food app.
- `brandCream` as ambient background — replaced by `bg-canvas`.
- `brandIvory` as card fill — replaced by `bg-surface` (pure white).
- `brandCreamSoft` — collapsed into `brand-soft`.
- `oliveDrab`, `oliveQuote`, `pinkGlow` — never carried weight, drop.

---

## Typography

### Font families
- **M PLUS Rounded 1c** (PostScript family `Rounded Mplus 1c`): hero numbers, big titles only.
- **Nunito**: everything else — body, nav, captions, labels.

The previous design overused M PLUS for too many things. Now it's reserved for moments that need brand voice.

### Type scale

| Token | Size | Family | Weight | Tracking | Use |
|---|---|---|---|---|---|
| `hero-number` | 88pt | M PLUS | Black 900 | -3 | THE calorie number on Result. The number on Tracker. The one number per screen that earns the largest scale. |
| `display-1` | 42pt | M PLUS | Bold 700 | -1.2 | Onboarding hero ("What did you eat?"), section opening pages. |
| `display-2` | 32pt | Nunito | ExtraBold 800 | -0.8 | Food name on Result, "May 9" on Tracker. |
| `title-1` | 20pt | Nunito | ExtraBold 800 | -0.3 | Card titles, sheet headers. |
| `title-2` | 17pt | Nunito | ExtraBold 800 | -0.2 | Pill button label, section headers. |
| `body` | 16pt | Nunito | Regular 400 | 0 | Default body text, paragraph content. |
| `body-emphasis` | 16pt | Nunito | SemiBold 600 | 0 | Body text needing weight. |
| `chip-number` | 20pt | Nunito | ExtraBold 800 | -0.3 | Numbers in macro chips. |
| `caption` | 13pt | Nunito | SemiBold 600 | 0 | Card meta lines, timestamps. |
| `caption-strong` | 13pt | Nunito | ExtraBold 800 | 0 | Card meta where emphasis is needed. |
| `label-eyebrow` | 11pt | Nunito | ExtraBold 800 | 2.0 | Small UPPERCASE labels above hero numbers ("CALORIES", "DETECTED"). |

### Weight semantics

The previous design used non-standard CSS weights (660, 680, 850, 960). Drop those. Bundled weights are:

- M PLUS: 300, 400, 500, 700, 800, 900
- Nunito: 400, 600, 700, 800

`AppFont.weight(_:)` mapping helper is no longer needed since we don't borrow web weights anymore.

### Numbers must be tabular

Apply `.monospacedDigit()` to every `Text` rendering numerical data. Without this, "1,247 calories" → "1,300 calories" makes the digit columns shift visibly during count-up animations. Tabular figures keep columns locked.

---

## Spacing

Renamed and simplified. The old token names (`xl5`, `xl6`) remain valid as aliases but the canonical names are step numbers:

| Token | Pt | Old name |
|---|---|---|
| `space-1` | 4 | xs |
| `space-2` | 8 | sm |
| `space-3` | 12 | (new) |
| `space-4` | 16 | md |
| `space-5` | 24 | lg |
| `space-6` | 32 | xl |
| `space-7` | 48 | xl2 |
| `space-8` | 64 | xl3 |
| `space-9` | 96 | xl4 |

### Vertical rhythm rules

- Tab bar bottom edge to safe area: 0
- Top safe area to header: `space-4` (16pt)
- Header to first content block: `space-7` (48pt) — this is the new "breathing room" gap
- Section to section within a screen: `space-7` (48pt)
- Block to block within a section: `space-5` (24pt)
- Inside a card: `space-4` (16pt) padding, `space-3` (12pt) between content rows

### Edge padding

- Default screen edge padding: `space-5` (24pt) on both sides — wider than the old default of 16pt. This is one of the cheapest premium upgrades.
- Cards within screens: full edge-to-edge of the content area, no double-padding.

---

## Radius

| Token | Pt | Use |
|---|---|---|
| `radius-sm` | 12 | Macro chips, small inline pills. |
| `radius-md` | 16 | Meal card thumbnails (within cards). |
| `radius-lg` | 20 | Cards, accordion rows, sheet pills. |
| `radius-xl` | 24 | Photo cards, hero containers. |
| `radius-2xl` | 28 | Drop zone, large feature surfaces. |
| `radius-pill` | 9999 | Buttons, segmented control thumb, status chips. |

Radii are larger throughout than the old system. Premium iOS apps use generous corners — 20–28pt for cards, full pill for buttons.

---

## Shadow

Three shadow tokens. The old five-shadow system is collapsed.

| Token | Spec | Use |
|---|---|---|
| `shadow-card` | 0 6 14 rgba(0,0,0,0.05) | Default card lift. |
| `shadow-cta` | 0 8 16 rgba(184,202,56,0.18) | Primary CTA — colored shadow that ties to brand. |
| `shadow-floating` | 0 4 10 rgba(0,0,0,0.08) | Floating elements (coach badge, segmented thumb). |

Shadows are softer and more diffuse than the old `card`/`cardHover` stack. The old multi-layer shadow stack was a Bootstrap-era pattern; modern iOS uses single-layer soft shadows.

---

## Component patterns

### `HeroNumber`
A two-line stacked treatment: small UPPERCASE eyebrow label at 11pt, then the number at 88pt. Tabular figures. Used on Result (calories) and inside the Tracker progress ring (with adapted size).

### `MacroChip`
64pt tall pill: small UPPERCASE label at the top in `ink-light`, large number below in `ink` with unit in `ink-mute`. Used in a horizontal scroll row of 3–4 chips on Result.

### `CategoryAccordion`
A 56pt-tall row with: monogram badge (28×28 circle with category letter in tinted bg), title, count badge, chevron. Tap expands inline. Replaces the old AnalysisPanel for revisit (saved meal) contexts. The original AnalysisPanel with full typewriter is kept ONLY for the post-analyze flow on the Result screen.

### `EditorialQuote`
Large open-quote glyph (64pt M PLUS Black, brand color at 55% opacity), then italic quote text in Nunito SemiBold at 17pt, then a 36pt horizontal rule and the attribution name in Nunito ExtraBold 12pt.

### `ProgressRing`
The Tracker hero. 92pt radius, 14pt stroke. Background ring in `border-hairline`, progress arc in a brand gradient (`#B8CA38` → `#8DA12C`) with `stroke-linecap: round`. Center renders the eyebrow + number + "of 2,000" goal context.

### `MacroProgressBar`
A row showing label + value/goal + a 6pt-thick progress bar. Three rows on Tracker (carbs, sugar, protein), each with their semantic accent color.

### `MealCard`
76pt tall card: 56×56 photo thumbnail on the left, food name + meta + macros on the right, chevron right. The photo placement makes meals scannable visually.

### `CoachBadge`
A floating 32pt-tall pill with avatar circle (single letter or photo) and coach name. Renders over the photo on the Result screen. Material backdrop.

### `PrimaryButton`
60pt tall, full width minus screen padding, `radius-pill`, brand fill, `ink` text (yes, dark text on lime — the contrast ratio works), 17pt ExtraBold, optional leading icon. `shadow-cta` for the colored shadow under it.

### `SegmentedControl`
40pt tall, soft surface track, white thumb with `shadow-floating`. Three segments equal-width. Replaces the default SwiftUI `.pickerStyle(.segmented)` which feels generic.

### Retired components
- `DashedDropZone` — drop the dashed border treatment, replaced with a clean white card + centered icon. Web-form vibe gone.
- `BouncingBadge` — perpetual ambient motion is exhausting. Replaced with quiet category badges. The "free!" pill on sign-in becomes a static `radius-pill` accent.
- `BlurredNavBar` — there's no nav bar on the new screens. Top header is just text + avatar.
- `SpeechBubble` — replaced by `EditorialQuote` for revisit contexts. The post-analyze flow can keep the chat-bubble feel if desired, but as a one-time delight, not a default.

---

## Motion

### Tokens
| Token | Spec | Use |
|---|---|---|
| `motion-quick` | 0.2s easeOut | Tab switches, segment changes, small UI swaps. |
| `motion-base` | 0.3s easeOut | Sheet presentations, fades, common transitions. |
| `motion-press` | 0.25s spring(0.7) | Press states. |
| `motion-reveal` | 0.5s spring(0.8) | Content appearances, expansions. |
| `motion-hero` | 0.8s easeOut + scale 0.95→1.0 | Hero number reveal on Result. |
| `motion-celebration` | 1.2s spring(0.65) | Save success choreography. |

### Interaction motion catalog

- **Photo pick** → photo fades in with scale 0.95→1.0 over 0.5s. Light haptic on land.
- **Hero number reveal** → count up from 0 to value over 0.8s with `easeOut`. Tabular numerals; no jitter.
- **Macro chips** → stagger in from below with 80ms delay each, 0.4s spring.
- **Accordion expand** → 0.4s spring, content slides down from above with opacity.
- **Segment switch** → cross-fade at 0.2s. Selection haptic.
- **Save success** → checkmark scales 0→1 with spring (0.65 damping for slight overshoot), brand-tinted radial pulse expands and fades, success haptic at peak.
- **Pull-to-refresh** → standard iOS spinner in brand color.

### What does NOT animate
- The brand lime never fades or pulses on idle screens.
- Numbers don't "tick" except on count-up entrance and on save-triggered total updates.
- No perpetual motion. No bouncing badges. No idle-state animation anywhere.

---

## Screen layouts

### Capture (Home)
```
┌───────────────────────────┐
│ 9:41          • • •       │
│                           │
│  foodie.        ◯ avatar  │
│                           │
│  What did                 │ display-1, ink
│  you eat?                 │ display-1, ink + brand "?"
│  Snap a meal — we'll      │ body, ink-mute
│  break it down.           │
│                           │
│  ┌───────────────────┐    │
│  │                   │    │
│  │       ●●●         │    │ photo placeholder card
│  │      camera       │    │
│  │                   │    │
│  │  Tap to add photo │    │ title-1, ink
│  │  Library or camera│    │ caption, ink-light
│  │                   │    │
│  └───────────────────┘    │
│                           │
│  • Best with bright light │ small chip hint
│                           │
│                           │
│  [    Take a photo    ]   │ PrimaryButton, brand
│                           │
│  ━━━━━━━━━━━━━━━━━━━━━━   │
│   📷       📅       👤    │
│  Capture  Today    You    │
└───────────────────────────┘
```

Empty drop zone is a clean white card. The CTA pinned at bottom takes the user to the source picker. The dashed border is gone.

### Result (post-analyze)
```
┌───────────────────────────┐
│ ‹     ANALYSIS            │ small back chevron + label
│                           │
│  ┌───────────────────┐    │
│  │                   │    │
│  │   [photo: pizza]  │    │ photo card, 4:3
│  │                   │    │
│  │  ⨀ Albert Einstein│    │ floating coach badge
│  └───────────────────┘    │
│                           │
│  DETECTED                 │ label-eyebrow, brand
│  Margherita Pizza         │ display-2, ink
│                           │
│  CALORIES                 │ label-eyebrow, ink-mute
│  285             ⊙ 14%    │ hero-number + small ring
│                           │   showing % of daily goal
│  [35g] [4g] [12g] [+3]    │ MacroChips row
│                           │
│  "                        │ EditorialQuote
│    E = mc²… and a slice   │
│    of pizza ≈ 285 kcal.   │
│    Pace thyself.          │
│   ── Albert Einstein      │
│                           │
│  [N] Nutrients      3  ›  │ collapsed accordions
│  [B] Benefits       3  ›  │
│  [D] Drawbacks      3  ›  │
│                           │
│  [   Save to today   ]    │ pinned bottom
│   Discard                 │
└───────────────────────────┘
```

The photo dominates. Hero number is unmistakable. Macro chips are scannable in one glance. Coach is editorial. Analysis sections collapsed, available on demand.

### Today (Tracker)
```
┌───────────────────────────┐
│ 9:41          • • •       │
│                           │
│  [Today  Week    Month ]  │ custom segmented control
│                           │
│  SATURDAY                 │ label-eyebrow
│  May 9                    │ display-2
│                           │
│       ╭─────────╮         │
│      ╱  CALORIES ╲        │ ProgressRing
│     │             │       │
│     │   1,247     │       │ hero-number-ish (56pt fits ring)
│     │  of 2,000   │       │
│      ╲           ╱        │
│       ╰─────────╯         │
│                           │
│  Carbs       142 / 250 g  │ MacroProgressBar
│  ▓▓▓▓▓▓▓▓░░░░░░           │
│  Sugar        28 / 50 g   │
│  ▓▓▓▓▓▓▓▓▓░░░░░           │ accent-warm
│  Protein      52 / 90 g   │
│  ▓▓▓▓▓▓▓▓▓░░░░░           │ accent-cool
│                           │
│  YOUR MEALS    2 today    │ label-eyebrow + brand count
│                           │
│  [thumb] Margherita…  ›   │ MealCard
│         12:30 PM · 285 cal│
│                           │
│  [thumb] Greek Salad  ›   │ MealCard
│         7:15 AM · 962 cal │
└───────────────────────────┘
```

One hero number. Three progress bars in semantic colors. Meals as photo-first cards.

---

## Implementation notes

### Don't break what works
- The Supabase data layer is unchanged.
- The Gemini server contract is unchanged.
- The Phase 1–12 feature set (auth, save loop, RLS, image normalization, full-image viewer, meal expansion) all keep working.
- The redesign is purely a UI layer — replacing color tokens, type styles, layouts, and components.

### Don't over-engineer
- Keep the existing `AppColor`, `AppFont`, `AppSpacing`, etc. files. Add new tokens, deprecate old ones in place. Don't rename files unless necessary.
- The retired colors stay in `Assets.xcassets` for one phase to avoid breaking previews; mark with `// DEPRECATED:` comments and remove in a follow-up phase.
- The `DashedDropZone` component file can be deleted entirely; the new empty-state card is simple enough to inline in `CaptureView`.

### Photo treatment
The user's saved JPEGs aren't going to be magazine-quality. To make them look intentional:
- Apply `.aspectRatio(4/3, contentMode: .fill)` and `.clipShape(RoundedRectangle(cornerRadius: 24))`
- Subtle bottom-edge gradient overlay (`#181715` 0% → 45%) so floating badges remain readable
- No filters, no saturation boosts — respect the user's photo

### Tabular numerals
Every `Text` rendering a number needs `.monospacedDigit()`. Build it into a tiny `Text.number(_:)` extension so call sites are uniform.

### Dark mode
v1 was light-only and stays light-only for this redesign. Dark variants are a future phase.
