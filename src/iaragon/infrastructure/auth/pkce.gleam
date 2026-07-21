//// PKCE (RFC 7636) for the OAuth desktop loopback flow: Google removed OOB,
//// so native apps authorize via http://127.0.0.1:{port} with a code
//// challenge. S256 only — plain is pointless when SHA-256 is available.

import gleam/bit_array
import gleam/crypto

/// 32 random octets → 43 URL-safe chars, the RFC's recommended entropy.
pub fn generate_verifier() -> String {
  encode_verifier(crypto.strong_random_bytes(32))
}

/// Base64url without padding, as RFC 7636 requires. Split from
/// `generate_verifier` so tests can inject known bytes.
pub fn encode_verifier(bytes: BitArray) -> String {
  bit_array.base64_url_encode(bytes, False)
}

/// code_challenge = base64url(sha256(ascii(verifier))), no padding.
pub fn derive_challenge(verifier: String) -> String {
  crypto.hash(crypto.Sha256, <<verifier:utf8>>)
  |> bit_array.base64_url_encode(False)
}
