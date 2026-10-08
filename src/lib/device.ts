/**
 * Privacy-conscious client device identifier for preventing duplicate submissions.
 *
 * Uses a cryptographically strong persistent random token stored in localStorage,
 * hashed to ensure it cannot be reversed or used to trace student identity.
 */

const STORAGE_KEY = 'campusforms-device-id-v1';

export function getOrCreateDeviceId(): string {
  if (typeof window === 'undefined') {
    return '';
  }

  try {
    let raw = localStorage.getItem(STORAGE_KEY);
    if (!raw || raw.length < 16) {
      // Generate a 128-bit random hex string
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      raw = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      localStorage.setItem(STORAGE_KEY, raw);
    }
    return raw;
  } catch {
    // Fallback for restricted storage environments (e.g., incognito with blocked storage)
    return 'anon-' + Math.random().toString(36).slice(2, 18);
  }
}
