const messagesEl = document.getElementById('messages');
const inputEl = document.getElementById('input');
const sendBtn = document.getElementById('send');
const statusEl = document.getElementById('status');
const errorBanner = document.getElementById('error-banner');

let currentStreamingEl = null;
let currentThinkingContent = '';
let pendingToolCalls = {};

(async function init() {
  try {
    const res = await fetch('/api/messages');
    const data = await res.json();
    data.messages.forEach(msg => renderMessage(msg.content, msg.isFromMe, msg.thinkingContent));
    scrollToBottom();
  } catch (e) {
    showError('Failed to load messages');
  }
})();

inputEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') sendMessage();
});

function sendMessage() {
  const text = inputEl.value.trim();
  if (!text || text.length > 5000) return;

  renderMessage(text, true);
  inputEl.value = '';
  scrollToBottom();

  sendBtn.disabled = true;
  inputEl.disabled = true;
  statusEl.textContent = '● streaming';
  statusEl.style.color = '#ffd700';

  currentStreamingEl = null;
  currentThinkingContent = '';
  pendingToolCalls = {};

  fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: text })
  }).then(async (response) => {
    if (!response.ok) {
      const err = await response.json();
      showError(err.error || 'Request failed');
      resetInput();
      return;
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const jsonStr = line.slice(6);
        if (jsonStr === '[DONE]') {
          finalizeStream();
          return;
        }
        try {
          handleSSEEvent(JSON.parse(jsonStr));
        } catch (e) {}
      }
    }
    finalizeStream();
  }).catch(e => {
    showError('Connection lost: ' + e.message);
    resetInput();
  });
}

function handleSSEEvent(event) {
  switch (event.type) {
    case 'token':
      if (!currentStreamingEl) currentStreamingEl = createStreamingBubble();
      currentStreamingEl.querySelector('.content').textContent += event.data;
      scrollToBottom();
      break;
    case 'thinking':
      currentThinkingContent += event.data;
      if (currentStreamingEl) {
        const thinkEl = currentStreamingEl.querySelector('.thinking-block');
        thinkEl.textContent = currentThinkingContent;
        thinkEl.classList.add('visible');
      }
      break;
    case 'toolCall':
      pendingToolCalls[event.id] = { name: event.name, result: null };
      if (currentStreamingEl) {
        const toolsEl = currentStreamingEl.querySelector('.tool-calls');
        const div = document.createElement('div');
        div.className = 'tool-call';
        div.id = 'tool-' + event.id;
        div.innerHTML = '<span class="name">\u{1F527} ' + event.name + '</span><div class="result">Running...</div>';
        toolsEl.appendChild(div);
        scrollToBottom();
      }
      break;
    case 'toolResult':
      if (pendingToolCalls[event.id]) pendingToolCalls[event.id].result = event.data;
      const toolDiv = document.getElementById('tool-' + event.id);
      if (toolDiv) {
        const resultDiv = toolDiv.querySelector('.result');
        if (isScreenshotPath(event.data, event.name)) {
          const filename = event.data.split('/').pop();
          resultDiv.innerHTML = '<img src="/api/files/screenshots/' + filename + '" class="screenshot" loading="lazy" onclick="this.classList.toggle(\'expanded\')">';
        } else {
          const truncated = event.data.length > 500 ? event.data.slice(0, 500) + '...' : event.data;
          resultDiv.textContent = truncated;
        }
      }
      break;
    case 'done':
      finalizeStream();
      break;
    case 'error':
      showError(event.data);
      resetInput();
      break;
  }
}

function isScreenshotPath(data, toolName) {
  return toolName === 'screenshot' && data && data.endsWith('.png');
}

function createStreamingBubble() {
  const div = document.createElement('div');
  div.className = 'msg agent streaming';
  div.innerHTML = '<div class="thinking-block"></div><div class="tool-calls"></div><div class="content"></div>';
  messagesEl.appendChild(div);
  return div;
}

function finalizeStream() {
  if (currentStreamingEl) {
    currentStreamingEl.classList.remove('streaming');
    embedScreenshotImages(currentStreamingEl);
    currentStreamingEl = null;
  }
  resetInput();
  scrollToBottom();
}

function renderMessage(content, isFromMe, thinkingContent) {
  const div = document.createElement('div');
  div.className = 'msg ' + (isFromMe ? 'user' : 'agent');
  if (thinkingContent) {
    const think = document.createElement('div');
    think.className = 'thinking-block visible';
    think.textContent = thinkingContent;
    div.appendChild(think);
  }
  const contentSpan = document.createElement('span');
  contentSpan.className = 'content';
  contentSpan.textContent = content;
  div.appendChild(contentSpan);
  embedScreenshotImages(div);
  messagesEl.appendChild(div);
}

function embedScreenshotImages(container) {
  const pattern = /(\/[\w\/.-]*screenshots\/([\w.-]+\.png))/gi;

  container.querySelectorAll('.content, .result').forEach(function(el) {
    const text = el.textContent || '';
    if (!pattern.test(text)) return;
    pattern.lastIndex = 0;

    let html = el.innerHTML;
    html = html.replace(pattern, function(match, fullPath, filename) {
      return fullPath + '<br><img src="/api/files/screenshots/' + filename + '" class="screenshot-inline" loading="lazy" onclick="this.classList.toggle(\'expanded\')">';
    });
    el.innerHTML = html;
  });
}

function newConversation() {
  fetch('/api/new-conversation', { method: 'POST' }).then(() => {
    messagesEl.innerHTML = '';
    currentStreamingEl = null;
    hideError();
  });
}

function resetInput() {
  sendBtn.disabled = false;
  inputEl.disabled = false;
  inputEl.focus();
  statusEl.textContent = '● connected';
  statusEl.style.color = '#4ec9b0';
}

function showError(msg) {
  errorBanner.textContent = msg;
  errorBanner.style.display = 'block';
  setTimeout(hideError, 5000);
}

function hideError() {
  errorBanner.style.display = 'none';
}

function scrollToBottom() {
  requestAnimationFrame(() => {
    messagesEl.scrollTop = messagesEl.scrollHeight;
  });
}
