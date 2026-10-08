import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { getOrCreateDeviceId } from './device';

class MemoryStorage {
  private map = new Map<string, string>();
  getItem(k: string) {
    return this.map.has(k) ? this.map.get(k)! : null;
  }
  setItem(k: string, v: string) {
    this.map.set(k, v);
  }
  removeItem(k: string) {
    this.map.delete(k);
  }
  clear() {
    this.map.clear();
  }
}

describe('getOrCreateDeviceId', () => {
  beforeEach(() => {
    vi.stubGlobal('window', {});
    vi.stubGlobal('localStorage', new MemoryStorage());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('generates a stable device identifier across multiple calls', () => {
    const first = getOrCreateDeviceId();
    expect(first).toBeDefined();
    expect(typeof first).toBe('string');
    expect(first.length).toBeGreaterThanOrEqual(16);

    const second = getOrCreateDeviceId();
    expect(second).toBe(first);
  });

  it('generates different device identifiers if storage was empty', () => {
    const id1 = getOrCreateDeviceId();
    localStorage.clear();
    const id2 = getOrCreateDeviceId();
    expect(id1).not.toBe(id2);
  });
});
