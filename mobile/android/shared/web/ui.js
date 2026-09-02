export function byId(id) {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing element #${id}`);
  return element;
}

export function setBusy(button, busy, busyLabel = 'Working…') {
  if (!button.dataset.idleLabel) {
    button.dataset.idleLabel = button.textContent.trim();
  }
  button.disabled = Boolean(busy);
  button.setAttribute('aria-busy', String(Boolean(busy)));
  button.textContent = busy ? busyLabel : button.dataset.idleLabel;
}

export function setStatus(element, message, tone = 'neutral') {
  element.textContent = message;
  element.dataset.tone = tone;
  element.hidden = !message;
}

export function formatData(value) {
  if (typeof value === 'string') return value;
  return JSON.stringify(value, null, 2);
}

export function autosize(textarea, maxHeight = 320) {
  textarea.style.height = 'auto';
  textarea.style.height = `${Math.min(textarea.scrollHeight, maxHeight)}px`;
}

export function shortValue(value, head = 12, tail = 8) {
  const text = String(value ?? '');
  if (tail <= 0) return text.length <= head ? text : `${text.slice(0, head)}…`;
  if (text.length <= head + tail + 1) return text;
  return `${text.slice(0, head)}…${text.slice(-tail)}`;
}

export function clockTime(date = new Date()) {
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
