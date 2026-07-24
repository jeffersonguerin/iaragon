# Mark every claim as verified fact or inference; never dress an assumption as confirmed

**Scope:** project (all reporting to the user — reviews, findings, status,
answers)
**Trigger:** about to tell the user that something is the case.

Distinguish what you verified from what you inferred, and label the inferred
as inferred. When a review finding is not traced end to end, tag its
confidence (e.g. CONFIRMED / LIKELY / THEORETICAL) rather than presenting it
flat as fact.

- The failure mode: stating a plausible inference in the same confident voice
  as a checked fact, so the user can't tell which claims to trust — and a
  wrong one silently becomes "known".
- This is the honesty half of `verify-in-code-not-memory.md` and
  `never-invent-drive-or-library-behavior.md`: those say go check; this says
  when you didn't (or couldn't), say so out loud.
- Observable check: uncertain claims carry a hedge or a confidence tag; a
  reader can point to which statements were verified this session and how.
  Warn about risks and unknowns BEFORE they propagate, not after.
