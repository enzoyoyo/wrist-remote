export const PROTOCOL_VERSION = 3;
export const MAX_CLOCK_SKEW_MS = 30_000;
export const MAX_FRAME_LIFETIME_MS = 30_000;
export const MAX_CIPHERTEXT_BYTES = 512 * 1024;
export const MAX_JSON_BYTES = 720 * 1024;
// The Codex queue subprocess has its own strict five-second deadline. Leave
// room for WAN and WebSocket round trips without allowing an offline queue.
export const RESPONSE_TIMEOUT_MS = 15_000;
export const RATE_LIMIT_WINDOW_MS = 10_000;
export const RATE_LIMIT_MAX_REQUESTS = 120;

// 32 bytes encode to 43 unpadded base64url characters. With two source bytes
// in the final quantum, the last character has 16 valid values (not four).
export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/;

export function isValidRelayToken(value: string): boolean {
  return TOKEN_PATTERN.test(value);
}
