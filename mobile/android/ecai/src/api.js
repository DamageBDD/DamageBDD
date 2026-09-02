import { joinUrl, requestJson } from './shared/http.js';

function contentToText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => part?.text || part?.content || '')
      .filter(Boolean)
      .join('\n');
  }
  return '';
}

export function extractAssistantText(data) {
  if (typeof data === 'string') return data;

  const direct = [
    data?.reply,
    data?.response,
    data?.output_text,
    data?.text,
    data?.content
  ].find((value) => typeof value === 'string' && value.trim());
  if (direct) return direct;

  const messageContent = contentToText(data?.message?.content);
  if (messageContent) return messageContent;

  const choiceContent = contentToText(data?.choices?.[0]?.message?.content);
  if (choiceContent) return choiceContent;

  const outputContent = contentToText(data?.output?.[0]?.content);
  if (outputContent) return outputContent;

  return JSON.stringify(data, null, 2);
}

export async function sendChat({ baseUrl, path, token, model, messages }) {
  const payload = {
    messages: messages.map(({ role, content }) => ({ role, content })),
    stream: false
  };

  if (model) payload.model = model;

  const response = await requestJson(joinUrl(baseUrl, path), {
    method: 'POST',
    token,
    data: payload
  });

  return {
    text: extractAssistantText(response.data),
    raw: response.data
  };
}
