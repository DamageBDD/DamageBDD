function resolveStorage(area) {
  try {
    return area === 'session' ? window.sessionStorage : window.localStorage;
  } catch {
    return null;
  }
}

export function createStore(prefix, area = 'local') {
  const storage = resolveStorage(area);
  const keyFor = (key) => `${prefix}${key}`;

  return {
    get(key, fallback = null) {
      if (!storage) return fallback;
      const raw = storage.getItem(keyFor(key));
      if (raw === null) return fallback;
      try {
        return JSON.parse(raw);
      } catch {
        return fallback;
      }
    },

    set(key, value) {
      if (!storage) return;
      storage.setItem(keyFor(key), JSON.stringify(value));
    },

    remove(key) {
      storage?.removeItem(keyFor(key));
    },

    clear() {
      if (!storage) return;
      for (let index = storage.length - 1; index >= 0; index -= 1) {
        const key = storage.key(index);
        if (key?.startsWith(prefix)) storage.removeItem(key);
      }
    }
  };
}
