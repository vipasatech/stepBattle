# Design System Strategy: Kinetic Competition

## 1. Overview & Creative North Star
The Creative North Star for this system is **"The Digital Arena."** 

We are moving away from the static, utility-focused layout of traditional fitness trackers. Instead, this design system treats the interface as a high-stakes, competitive environment. It blends the high-performance editorial aesthetic of elite athletics with the dopamine-driven feedback loops of modern gaming. 

To break the "template" look, we utilize **intentional asymmetry**. Hero elements should feel like they are "breaking out" of their containers. We favor aggressive typography scales and overlapping elements—where a user's avatar might slightly overlap a progress bar—to create a sense of forward motion and physical depth. This is not just an app; it is a live leaderboard where every pixel vibrates with energy.

---

## 2. Colors & Tonal Depth
Our palette is rooted in a deep, nocturnal foundation punctuated by a high-frequency "Electric Blue."

### Core Palette
- **Background (`#0e0e10`):** The absolute void. Use this for the deepest layer of the UI.
- **Primary (`#84adff` / `#1A73E8`):** The "Pulse." Use this for active competitive states and primary progress.
- **Tertiary (`#fab0ff`):** The "Rank-Up." Reserved for legendary achievements, rare badges, or "boss" level challenges.

### The "No-Line" Rule
Traditional 1px borders are strictly prohibited. Boundaries must be defined through **Tonal Transition**. 
- To separate a card from the background, use `surface-container-low` on a `surface` background. 
- The contrast between these subtle grey shifts creates a premium, "milled" look rather than a boxed-in feel.

### Surface Hierarchy & Nesting
Treat the UI as a series of physical plates. 
1. **The Floor:** `surface` (The base app experience).
2. **The Podium:** `surface-container-low` (General content areas).
3. **The Spotlight:** `surface-container-highest` (Active battle cards or focused stats).

### The "Glass & Glow" Rule
To achieve the "gamified" energy, main action cards should utilize **Glassmorphism**. Use `surface-variant` with a 60% opacity and a `backdrop-blur` of 20px. 
**Signature Texture:** Apply a 2px inner glow (drop shadow with 0 distance and 4px blur) using `primary` at 20% opacity to give cards a "powered-on" appearance.

---

## 3. Typography: The Editorial Edge
We use a dual-typeface system to balance high-tech precision with human performance.

- **Display & Headlines (Space Grotesk):** This is our "Aggressor" font. Use `display-lg` (3.5rem) for step counts and `headline-md` (1.75rem) for battle titles. Its wide, technical stance evokes a digital scoreboard.
- **Body & Labels (Manrope):** Our "Engine" font. It is highly legible at small sizes (`body-sm` 0.75rem) and provides the necessary grounding for complex data sets and social feeds.

**Hierarchy Note:** Always lead with size. If a number is important (e.g., "12,400 Steps"), use `display-lg`. Don't make it bold; make it massive. Let the scale communicate the importance.

---

## 4. Elevation & Depth
In "The Digital Arena," we don't use shadows to show height; we use **Light and Layering**.

- **The Layering Principle:** Stack `surface-container-lowest` cards on `surface-container-low` backgrounds. This "recessed" look feels more integrated than a floating card.
- **Ambient Shadows:** For floating action buttons or modal alerts, use a shadow color tinted with `primary` (e.g., `#002c65` at 15% opacity) with a 40px blur. This creates a "glow" rather than a "shadow," suggesting the element is emitting energy.
- **Ghost Borders:** If a boundary is strictly required for accessibility, use `outline-variant` at 15% opacity. It should be felt, not seen.

---

## 5. Components

### Buttons
- **Primary:** Gradient from `primary` to `primary-container`. High-energy, rounded (`full`), with a subtle outer glow on hover.
- **Secondary:** `surface-container-high` background with `on-surface` text. No border.
- **Tertiary:** Ghost style. Transparent background, `primary` text, no border.

### Progress Bars (The "Battle Gauge")
Forgo the standard flat bar. Use a `surface-container-highest` track. The fill should be a gradient of `primary` to `secondary`. For competitive "battles," add a "spark" element (a small white glow) at the leading edge of the progress bar to show momentum.

### Battle Cards
- **Construction:** Use `xl` (1.5rem) corner radius. 
- **Content:** No dividers. Use `title-md` for the opponent's name and `display-sm` for the score. 
- **The "Winner" State:** When a user is winning, the card should transition to a `secondary-container` background with a subtle pulse animation.

### Inputs
- **Field:** `surface-container-low` with a `sm` (0.25rem) corner radius. 
- **Focus State:** Instead of a thick border, the background should shift to `surface-container-high` and the label color should switch to `primary`.

---

## 6. Do’s and Don’ts

### Do:
- **Do use "Power Tones":** Use `tertiary` (pink/purple) sparingly to highlight extreme rarity or high-tier "Battle Leagues."
- **Do use Vertical Rhythm:** Use the spacing scale to create massive gaps between unrelated sections to let the "Editorial" feel breathe.
- **Do embrace the Asymmetric:** Allow images of trainers or trophies to break the top edge of their cards.

### Don’t:
- **Don’t use Dividers:** Never use a line to separate list items. Use 16px of vertical space or a background color shift.
- **Don’t use Pure Black:** Stick to the `#0e0e10` background. Pure `#000000` kills the depth and makes the "Glassmorphism" look muddy.
- **Don’t use Standard Shadows:** Avoid "Drop Shadow: 0 4 4 Black 25%." It looks dated and "out-of-the-box." Always use tinted, diffused glows.