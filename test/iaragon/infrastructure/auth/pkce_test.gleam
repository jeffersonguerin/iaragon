import gleam/string
import iaragon/infrastructure/auth/pkce

pub fn challenge_matches_the_rfc_7636_vector_test() {
  // Verifier → challenge pair from RFC 7636 (verified locally with openssl).
  assert pkce.derive_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
}

pub fn encoding_32_bytes_yields_43_url_safe_chars_test() {
  let verifier =
    pkce.encode_verifier(<<
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
      21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    >>)
  assert string.length(verifier) == 43
  assert !string.contains(verifier, "=")
  assert !string.contains(verifier, "+")
  assert !string.contains(verifier, "/")
}

pub fn generated_verifiers_are_fresh_each_time_test() {
  let one = pkce.generate_verifier()
  let other = pkce.generate_verifier()
  assert one != other
  assert string.length(one) == 43
}
