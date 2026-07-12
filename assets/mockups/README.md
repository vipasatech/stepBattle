# Welcome-screen mockups

Drop one PNG per bottom-nav tab in this folder. The Welcome screen
carousel loads them by exact filename (see `lib/screens/auth/welcome_screen.dart`).

| File               | Slide caption                                    |
| ------------------ | ------------------------------------------------ |
| `home.jpeg`        | "Your day at a glance."                          |
| `battles.jpeg`     | "Battle friends in step races."                  |
| `track.jpeg`       | "Track every run."                               |
| `profile.jpeg`     | "Watch your progress climb."                     |
| `leaderboard.jpeg` | "Own the leaderboard."                           |

## Capture tips

- Use a device with a **9:19.5** aspect ratio (iPhone 15 Pro, Pixel 8) so
  the phone frame around each mockup fits without cropping. Screenshots
  from other aspect ratios still work — they'll be letterboxed inside
  the frame.
- Show the tab in its **most content-rich state** — a couple of active
  battles, some sessions on Track, a populated leaderboard, etc.
- Take shots in **dark mode** so they blend with the violet gradient
  behind the phone frame.
- Filenames are case-sensitive on real Android/iOS builds — keep them
  lowercase.

If a PNG is missing at build time the slide falls back to a plain
gradient with the caption only, so the carousel never crashes.
