import iaragon/infrastructure/drive/backoff

// Truncated exponential backoff with jitter, as recommended by the Drive API
// error guide: min(2^attempt * 1000ms + random jitter, 64s). Randomness is
// injected so the function stays pure.

pub fn first_retry_waits_about_one_second_test() {
  assert backoff.compute_delay_ms(attempt: 0, jitter_ms: 250) == 1250
}

pub fn delay_doubles_with_each_attempt_test() {
  assert backoff.compute_delay_ms(attempt: 1, jitter_ms: 0) == 2000
  assert backoff.compute_delay_ms(attempt: 2, jitter_ms: 0) == 4000
  assert backoff.compute_delay_ms(attempt: 3, jitter_ms: 0) == 8000
}

pub fn delay_is_truncated_at_sixty_four_seconds_test() {
  assert backoff.compute_delay_ms(attempt: 10, jitter_ms: 999) == 64_000
}

pub fn negative_attempt_counts_as_the_first_test() {
  assert backoff.compute_delay_ms(attempt: -1, jitter_ms: 0) == 1000
}
