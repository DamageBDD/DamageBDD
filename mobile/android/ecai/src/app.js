import { sendChat } from './api.js';
import { describeError, joinUrl, normalizeBaseUrl } from './shared/http.js';
import { createStore } from './shared/storage.js';
import { autosize, byId, clockTime, setBusy, setStatus } from './shared/ui.js';

const preferences = createStore('ecai.mobile.', 'local');
const session = createStore('ecai.mobile.session.', 'session');

const elements = {
  settingsToggle: byId('settingsToggle'),
  settingsCard: byId('settingsCard'),
  serverUrl: byId('serverUrl'),
  apiPath: byId('apiPath'),
  model: byId('model'),
  apiToken: byId('apiToken'),
  saveSettingsButton: byId('saveSettingsButton'),
  clearTokenButton: byId('clearTokenButton'),
  settingsStatus: byId('settingsStatus'),
  endpointLabel: byId('endpointLabel'),
  clearChatButton: byId('clearChatButton'),
  messages: byId('messages'),
  composerForm: byId('composerForm'),
  messageInput: byId('messageInput'),
  sendButton: byId('sendButton'),
  chatStatus: byId('chatStatus')
};

let messages = session.get('messages', [
  {
    role: 'assistant',
    content: 'ECAI mobile is ready. Open Settings and configure the chat endpoint.',
    at: Date.now()
  }
]);

function currentSettings() {
  return {
    baseUrl: normalizeBaseUrl(elements.serverUrl.value),
    path: elements.apiPath.value.trim() || '/api/chat',
    model: elements.model.value.trim(),
    token: elements.apiToken.value
  };
}

function updateEndpointLabel() {
  const { baseUrl, path } = currentSettings();
  if (!baseUrl) {
    elements.endpointLabel.textContent = 'Configure an endpoint';
    return;
  }

  try {
    elements.endpointLabel.textContent = joinUrl(baseUrl, path);
  } catch {
    elements.endpointLabel.textContent = baseUrl;
  }
}

function saveSettings() {
  const settings = currentSettings();
  elements.serverUrl.value = settings.baseUrl;
  elements.apiPath.value = settings.path;
  preferences.set('serverUrl', settings.baseUrl);
  preferences.set('apiPath', settings.path);
  preferences.set('model', settings.model);
  session.set('token', settings.token);
  updateEndpointLabel();
  setStatus(elements.settingsStatus, 'Settings saved.', 'success');
}

function toggleSettings(force) {
  const shouldOpen = force ?? elements.settingsCard.hidden;
  elements.settingsCard.hidden = !shouldOpen;
  elements.settingsToggle.setAttribute('aria-expanded', String(shouldOpen));
  elements.settingsToggle.textContent = shouldOpen ? 'Close' : 'Settings';
}

function appendMessage(role, content) {
  const item = { role, content, at: Date.now() };
  messages.push(item);
  session.set('messages', messages);
  renderMessage(item);
  elements.messages.scrollTop = elements.messages.scrollHeight;
}

function renderMessage(message) {
  const article = document.createElement('article');
  article.className = 'message';
  article.dataset.role = message.role;

  const meta = document.createElement('div');
  meta.className = 'message-meta';
  const speaker = document.createElement('span');
  const time = document.createElement('time');
  speaker.textContent = message.role === 'user' ? 'You' : message.role === 'assistant' ? 'ECAI' : 'System';
  time.textContent = clockTime(new Date(message.at || Date.now()));
  meta.append(speaker, time);

  const bubble = document.createElement('div');
  bubble.className = 'message-bubble';
  bubble.textContent = message.content;

  article.append(meta, bubble);
  elements.messages.append(article);
}

function renderMessages() {
  elements.messages.replaceChildren();
  messages.forEach(renderMessage);
  requestAnimationFrame(() => {
    elements.messages.scrollTop = elements.messages.scrollHeight;
  });
}

async function submitMessage(event) {
  event.preventDefault();
  const content = elements.messageInput.value.trim();
  if (!content) return;

  const settings = currentSettings();
  if (!settings.baseUrl) {
    toggleSettings(true);
    setStatus(elements.settingsStatus, 'Enter the ECAI server URL first.', 'danger');
    return;
  }

  saveSettings();
  appendMessage('user', content);
  elements.messageInput.value = '';
  autosize(elements.messageInput, 180);
  setBusy(elements.sendButton, true, 'Sending…');
  setStatus(elements.chatStatus, 'Waiting for ECAI…', 'info');

  try {
    const response = await sendChat({
      ...settings,
      messages: messages.filter(({ role }) => role === 'user' || role === 'assistant')
    });
    appendMessage('assistant', response.text || '(Empty response)');
    setStatus(elements.chatStatus, '', 'neutral');
  } catch (error) {
    setStatus(elements.chatStatus, describeError(error), 'danger');
  } finally {
    setBusy(elements.sendButton, false);
    elements.messageInput.focus();
  }
}

function clearChat() {
  messages = [
    {
      role: 'assistant',
      content: 'Conversation cleared. What would you like to work on?',
      at: Date.now()
    }
  ];
  session.set('messages', messages);
  renderMessages();
  setStatus(elements.chatStatus, 'Session conversation cleared.', 'info');
}

function clearToken() {
  elements.apiToken.value = '';
  session.remove('token');
  setStatus(elements.settingsStatus, 'Session bearer token cleared.', 'info');
}

function initialise() {
  elements.serverUrl.value = preferences.get('serverUrl', '');
  elements.apiPath.value = preferences.get('apiPath', '/api/chat');
  elements.model.value = preferences.get('model', '');
  elements.apiToken.value = session.get('token', '');

  renderMessages();
  updateEndpointLabel();

  if (!elements.serverUrl.value) toggleSettings(true);

  elements.settingsToggle.addEventListener('click', () => toggleSettings());
  elements.saveSettingsButton.addEventListener('click', saveSettings);
  elements.clearTokenButton.addEventListener('click', clearToken);
  elements.clearChatButton.addEventListener('click', clearChat);
  elements.composerForm.addEventListener('submit', submitMessage);
  elements.messageInput.addEventListener('input', () => autosize(elements.messageInput, 180));
  elements.messageInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      elements.composerForm.requestSubmit();
    }
  });
  for (const input of [elements.serverUrl, elements.apiPath, elements.model]) {
    input.addEventListener('change', updateEndpointLabel);
  }
}

initialise();
