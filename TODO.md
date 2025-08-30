TODO
====

- Improve signal recognition robustness:
  - AC-coupled mic inputs produce only transients. Our edge detector (HPF + debounce) works, but can still mis-toggle under heavy noise or AGC; tune or adapt thresholds dynamically.
  - Add polarity learning so the first post-idle edge maps deterministically to KEY DOWN.
  - Optional carrier-tone method (1 kHz) for sustained key-down detection without DC issues.

- Morse decoder improvements:
  - Auto WPM estimation and adaptive dot length.
  - Noise immunity and missed-edge recovery.
  - Configurable prosigns and punctuation set.

- UI:
  - Fading columns (e.g., * -> .) for history.
  - Optional color output when ANSI supported.

