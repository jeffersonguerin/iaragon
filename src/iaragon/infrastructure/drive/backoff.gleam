//// Truncated exponential backoff for Drive API quota errors (403/429
//// userRateLimitExceeded etc.), per the official error guide:
//// wait min(2^attempt × 1s + jitter, 64s). Pure: the caller supplies the
//// random jitter (0–999 ms) so tests stay deterministic.

import gleam/int

const base_ms = 1000

const cap_ms = 64_000

pub fn compute_delay_ms(attempt attempt: Int, jitter_ms jitter_ms: Int) -> Int {
  // 2^16 × 1s already exceeds the cap by far; clamping keeps the shift sane.
  let attempt = int.clamp(attempt, 0, 16)
  let exponential = int.bitwise_shift_left(1, attempt) * base_ms
  int.min(exponential + jitter_ms, cap_ms)
}
