/* /static/js/filter.js
 * AccountFilter component
 * - Tag cloud selector with add/remove
 * - Validates AE ids: ak_ / ct_ (base58check checksum)
 * - Optional allowedPrefixes (default ["ak_","ct_"])
 * - mode: "single" or "multi"
 * - localStorage persistence
 *
 * Requires: browser crypto.subtle
 */

(function () {
  "use strict";

  // --------------------------
  // Base58 + Base58Check utils
  // --------------------------
  const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  const B58_MAP = new Map([...B58_ALPHABET].map((c, i) => [c, i]));

  function base58Decode(str) {
    let num = 0n;
    for (const ch of str) {
      const v = B58_MAP.get(ch);
      if (v === undefined) return null;
      num = num * 58n + BigInt(v);
    }

    let bytes = [];
    while (num > 0n) {
      bytes.push(Number(num & 0xffn));
      num >>= 8n;
    }
    bytes.reverse();

    // leading '1' => 0x00
    let leadingZeros = 0;
    for (const ch of str) {
      if (ch === "1") leadingZeros++;
      else break;
    }

    return new Uint8Array([...new Array(leadingZeros).fill(0), ...bytes]);
  }

  async function sha256(bytes) {
    const hash = await crypto.subtle.digest("SHA-256", bytes);
    return new Uint8Array(hash);
  }

  async function base58checkChecksum(data) {
    const h1 = await sha256(data);
    const h2 = await sha256(h1);
    return h2.slice(0, 4);
  }

  function bytesEq(a, b) {
    if (!a || !b || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  function safeTrim(s) {
    return String(s ?? "").trim();
  }

  function shortId(id) {
    const s = safeTrim(id);
    if (s.length <= 16) return s;
    return s.slice(0, 6) + "…" + s.slice(-6);
  }

  function isAllowedPrefix(id, allowedPrefixes) {
    const p = id.slice(0, 3);
    return allowedPrefixes.includes(p);
  }

  async function isValidAeId(id, allowedPrefixes = ["ak_", "ct_"]) {
    id = safeTrim(id);
    if (id.length < 10) return false; // cheap sanity
    if (!isAllowedPrefix(id, allowedPrefixes)) return false;

    const payload = id.slice(3);
    if (!payload) return false;

    // base58 charset check
    for (const ch of payload) if (!B58_MAP.has(ch)) return false;

    const bytes = base58Decode(payload);
    if (!bytes || bytes.length < 5) return false;

    const data = bytes.slice(0, -4);
    const chk = bytes.slice(-4);
    const expected = await base58checkChecksum(data);
    return bytesEq(chk, expected);
  }

  // --------------------------
  // Component
  // --------------------------
  function AccountFilter(opts) {
    const {
      // Mounts + wiring
      tagsHostId,
      addInputId,
      addBtnId,
      hintId,
      // Behaviour
      mode = "single", // "single" | "multi"
      allowedPrefixes = ["ak_", "ct_"],
      storageKey = null,
      // Defaults provider: async () => [{ id, label, selected, locked }]
      getDefaults = null,
      // Callback: (selectedIds, primaryId) => void
      onChange = null,
      // Optional: set external input
      bindInputId = null,
      // Optional: show invalid state on bound input
      invalidClass = "invalid"
    } = opts || {};

    const qs = (s) => document.getElementById(s);

    const hostEl = qs(tagsHostId);
    const addInputEl = qs(addInputId);
    const addBtnEl = qs(addBtnId);
    const hintEl = hintId ? qs(hintId) : null;
    const bindInputEl = bindInputId ? qs(bindInputId) : null;

    if (!hostEl) throw new Error(`AccountFilter: missing tags host #${tagsHostId}`);

    // model
    const tags = []; // { id, label, selected, locked }
    const idx = new Map();

    function setHint(msg) {
      if (!hintEl) return;
      hintEl.textContent = msg || "";
    }

    function save() {
      if (!storageKey) return;
      try {
        const rows = tags.map((t) => ({
          id: t.id,
          label: t.label || "",
          selected: !!t.selected,
          locked: !!t.locked
        }));
        localStorage.setItem(storageKey, JSON.stringify(rows));
      } catch {}
    }

    function load() {
      if (!storageKey) return [];
      try {
        const raw = localStorage.getItem(storageKey);
        if (!raw) return [];
        const rows = JSON.parse(raw);
        return Array.isArray(rows) ? rows : [];
      } catch {
        return [];
      }
    }

    function render() {
      hostEl.innerHTML = "";

      for (const t of tags) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "addr-tag";
        b.setAttribute("aria-pressed", t.selected ? "true" : "false");
        b.title = t.id;

        const label = document.createElement("span");
        label.className = "addr-tag__label";
        label.textContent =
          t.label || (t.id.startsWith("ct_") ? "Contract" : "Account");

        const addr = document.createElement("span");
        addr.className = "addr-tag__addr";
        addr.textContent = shortId(t.id);

        b.appendChild(label);
        b.appendChild(addr);

        if (!t.locked) {
          const x = document.createElement("span");
          x.className = "addr-tag__x";
          x.textContent = "×";
          x.title = "Remove";
          x.addEventListener("click", (e) => {
            e.stopPropagation();
            remove(t.id);
          });
          b.appendChild(x);
        }

        b.addEventListener("click", () => toggleOrSelect(t.id));
        hostEl.appendChild(b);
      }
    }

    function selectedIds() {
      return tags.filter((t) => t.selected).map((t) => t.id);
    }

    function primaryId() {
      const sel = tags.find((t) => t.selected);
      return sel ? sel.id : null;
    }

    function emitChange() {
      const sel = selectedIds();
      const prim = mode === "single" ? primaryId() : null;

      if (bindInputEl && mode === "single") {
        bindInputEl.value = prim || "";
      }

      if (typeof onChange === "function") onChange(sel, prim);
      save();
    }

    function setInvalidBoundInput(msg) {
      if (!bindInputEl) return;
      bindInputEl.classList.add(invalidClass);
      bindInputEl.title = msg || "Invalid AE id";
    }

    function clearInvalidBoundInput() {
      if (!bindInputEl) return;
      bindInputEl.classList.remove(invalidClass);
      bindInputEl.title = "";
    }

    async function add(id, { label = "", selected = false, locked = false } = {}) {
      id = safeTrim(id);
      if (!id) return { ok: false, reason: "empty" };

      const ok = await isValidAeId(id, allowedPrefixes);
      if (!ok) return { ok: false, reason: "invalid" };

      if (idx.has(id)) {
        const t = idx.get(id);
        if (label && !t.label) t.label = label;
        if (selected) {
          if (mode === "single") {
            for (const x of tags) x.selected = false;
            t.selected = true;
          } else {
            t.selected = true;
          }
        }
        render();
        emitChange();
        return { ok: true, existed: true };
      }

      const t = { id, label, selected: !!selected, locked: !!locked };
      if (mode === "single" && t.selected) {
        for (const x of tags) x.selected = false;
      }
      tags.push(t);
      idx.set(id, t);

      render();
      emitChange();
      return { ok: true, existed: false };
    }

    function remove(id) {
      const t = idx.get(id);
      if (!t || t.locked) return;
      idx.delete(id);
      const i = tags.findIndex((x) => x.id === id);
      if (i >= 0) tags.splice(i, 1);
      render();
      emitChange();
    }

    async function toggleOrSelect(id) {
      const t = idx.get(id);
      if (!t) return;

      // validate before selecting to avoid persisting junk
      const ok = await isValidAeId(id, allowedPrefixes);
      if (!ok) {
        setHint("Invalid AE id (checksum failed).");
        setInvalidBoundInput("Invalid AE id (checksum failed).");
        return;
      }
      clearInvalidBoundInput();
      setHint("");

      if (mode === "single") {
        for (const x of tags) x.selected = false;
        t.selected = true;
      } else {
        t.selected = !t.selected;
      }

      render();
      emitChange();
    }

    async function handleAdd() {
      const val = safeTrim(addInputEl ? addInputEl.value : "");
      if (!val) return;

      const r = await add(val, { label: "Custom", selected: true, locked: false });
      if (!r.ok) {
        setHint(`Invalid id. Must be ${allowedPrefixes.join(" or ")} and checksum-valid.`);
        if (bindInputEl) setInvalidBoundInput("Invalid AE id");
        return;
      }

      if (addInputEl) addInputEl.value = "";
      clearInvalidBoundInput();
      setHint(`Added ${val}`);
    }

    function wire() {
      if (addBtnEl) addBtnEl.addEventListener("click", handleAdd);
      if (addInputEl) {
        addInputEl.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            handleAdd();
          }
        });
      }
    }

    async function init() {
      // restore saved
      for (const row of load()) {
        if (!row?.id) continue;
        // best-effort: don't block init on checksum failures (but skip invalid)
        try {
          const ok = await isValidAeId(row.id, allowedPrefixes);
          if (!ok) continue;
          tags.push({
            id: row.id,
            label: row.label || "",
            selected: !!row.selected,
            locked: !!row.locked
          });
          idx.set(row.id, tags[tags.length - 1]);
        } catch {}
      }

      // apply defaults
      if (typeof getDefaults === "function") {
        try {
          const defs = await getDefaults();
          if (Array.isArray(defs)) {
            for (const d of defs) {
              if (!d?.id) continue;
              await add(d.id, {
                label: d.label || "",
                selected: !!d.selected,
                locked: !!d.locked
              });
            }
          }
        } catch {}
      }

      // enforce single-select: if none selected, select first
      if (mode === "single") {
        const any = tags.some((t) => t.selected);
        if (!any && tags[0]) tags[0].selected = true;
      }

      render();
      emitChange();
      wire();
    }

    // public API
    return {
      init,
      add,
      remove,
      getSelected: selectedIds,
      getPrimary: primaryId
    };
  }

  // export
  window.AccountFilter = AccountFilter;
  window.AeId = { isValidAeId };
})();
