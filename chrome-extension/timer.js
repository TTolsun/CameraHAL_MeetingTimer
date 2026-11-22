'use strict';
const extensionWindow = location.protocol === 'chrome-extension:';

const el = id => document.getElementById(id);
const sessionKey = 'meeting-timer.v1';
let state = meeting(6, nextHour(Date.now()));
let previous = null;
try {
  const oldKey = Object.keys(sessionStorage).find(key => key.endsWith('.web-timer.v1'));
  const key = sessionStorage.getItem(sessionKey) !== null ? sessionKey : oldKey;
  const saved = key && JSON.parse(sessionStorage.getItem(key));
  if (saved && valid(saved.state)) {
    state = saved.state;
    previous = valid(saved.previous) ? saved.previous : null;
    if (key !== sessionKey) {
      sessionStorage.setItem(sessionKey, JSON.stringify({state, previous}));
      sessionStorage.removeItem(key);
    }
  }
} catch {}
function save() {
  try { sessionStorage.setItem(sessionKey, JSON.stringify({state, previous})); } catch {}
  render();
}
function mayStart(now, host) {
  return now < state.end || host.confirm('회의 종료 시각이 지났습니다. 다음 발표 시간을 초과 시간으로 기록할까요?');
}
function toggle(host = window) {
  const now = Date.now();
  if (state.started !== null) {
    state.elapsed += Math.max(0, now - state.started);
    state.started = null;
  } else {
    if (state.budget === null && !mayStart(now, host)) return;
    state.plan ??= state.budget ?? allocation(state, now);
    state.budget ??= allocation(state, now);
    state.started = now;
  }
  notify('');
  save();
}
function advance(host = window) {
  if (state.started === null) return;
  const now = Date.now();
  const last = state.index + 1 === state.count;
  if (!last && !mayStart(now, host)) return;
  previous = {...state};
  if (last) {
    state = meeting(state.count, nextHour(now));
    notify('회의 종료 · 되돌리기로 마지막 발표를 복원할 수 있습니다.', '회의 종료 · 되돌리기');
  } else {
    notify('');
    state.index++;
    state.budget = allocation(state, now);
    state.elapsed = 0;
    state.started = now;
  }
  save();
}
function undo() {
  if (!previous) return;
  state = previous;
  previous = null;
  notify('이전 발표로 돌아왔습니다.');
  save();
}
let mini = null;
let miniUI = null;
let tick = window.setInterval(render, 250);
let noticeTimeout;
let barNotice = '';
function notify(text, compact = '') {
  window.clearTimeout(noticeTimeout);
  el('notice').textContent = text;
  barNotice = compact;
  noticeTimeout = window.setTimeout(() => { el('notice').textContent = ''; barNotice = ''; }, 5000);
}
const icons = el('icons').content;
function iconFor(button, name) {
  const icon = button.ownerDocument.importNode(icons.querySelector('[data-icon="' + name + '"]'), true);
  icon.setAttribute('aria-hidden', 'true');
  return icon;
}
function setIconButton(button, label, name) {
  if (button.getAttribute('aria-label') === label) return;
  button.setAttribute('aria-label', label);
  button.title = label;
  button.replaceChildren(iconFor(button, name));
}
function chooseTheme(theme) {
  document.documentElement.dataset.theme = theme;
  if (miniUI) mini.document.documentElement.dataset.theme = theme;
  const dark = theme === 'dark';
  setIconButton(el('theme'), dark ? '밝은 화면으로 전환' : '어두운 화면으로 전환', dark ? 'sun' : 'moon');
  try { localStorage.setItem('timer-theme', theme); } catch {}
}
let initialTheme = 'light';
try { if (localStorage.getItem('timer-theme') === 'dark') initialTheme = 'dark'; } catch {}
chooseTheme(initialTheme);
el('theme').onclick = () => chooseTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
el('mini').prepend(iconFor(el('mini'), 'bar'));

function drawSpeakers(row, compact) {
  const key = state.index + '/' + state.count;
  if (row.dataset.speakers === key) return;
  row.dataset.speakers = key;
  row.replaceChildren();
  const first = compact ? Math.max(0, Math.min(state.index - 2, state.count - 5)) : 0;
  const last = compact ? Math.min(state.count, first + 5) : state.count;
  if (first > 0) row.append('…');
  for (let i = first; i < last; i++) {
    const mark = row.ownerDocument.createElement(compact ? 'span' : 'i');
    if (compact) mark.textContent = i + 1;
    if (state.index === i) {
      mark.className = compact ? 'active' : 'current';
      mark.setAttribute('aria-current', 'step');
    } else if (i < state.index) mark.className = 'done';
    row.append(mark);
  }
  if (last < state.count) row.append('…');
}
function render() {
  const now = Date.now();
  const rem = remaining(state, now);
  const budget = state.budget ?? allocation(state, now);
  const running = state.started !== null;
  const idle = state.budget === null;
  const paused = !idle && !running;
  const over = !idle && rem <= 0;
  const status = paused ? '일시정지' : running ? '진행 중' : '대기';
  const clock = duration(rem);
  const speaker = '발표자 ' + (state.index + 1);
  const runLabel = running ? '일시정지' : paused ? '계속' : '시작';
  const nextLabel = state.index + 1 === state.count ? '종료' : '다음';
  const progress = (budget ? Math.max(0, Math.min(1, 1 - rem / budget)) : Number(over)) * 100 + '%';
  const closing = running && rem > 0 && rem <= Math.max(minute, budget * .3);
  const seconds = Math.ceil(rem / 1000);
  const countdown = [Math.floor(seconds / 60) && Math.floor(seconds / 60) + '분', seconds % 60 && seconds % 60 + '초'].filter(Boolean).join(' ') + ' 남았어요';
  el('now').textContent = hour(now);
  const delta = state.plan == null ? 0 : budget - state.plan;
  el('delta').hidden = delta === 0;
  if (delta !== 0) {
    el('deltaValue').textContent = (delta < 0 ? '−' : '+') + duration(Math.abs(delta));
    el('delta').dataset.sign = delta < 0 ? 'minus' : 'plus';
  }
  el('speaker').textContent = speaker;
  el('clock').textContent = clock;
  el('clock').classList.toggle('over', rem <= -15000);
  el('status').textContent = over ? (paused ? '초과 · 일시정지' : '시간 초과') : status;
  el('budget').textContent = closing ? countdown : over || paused ? '' :
    idle && !budget ? '시작하면 초과 시간을 기록합니다' : '배정 ' + duration(budget) + (idle ? ' · 시작을 눌러 주세요' : '');
  el('deadline').textContent = hour(state.end);
  el('left').textContent = now >= state.end ? '회의 시간 종료' : Math.ceil((state.end - now) / minute) + '분 남음';
  el('left').classList.toggle('warn', now >= state.end);
  drawSpeakers(el('segments'), false);
  el('segments').style.setProperty('--progress', progress);
  el('run').textContent = runLabel;
  el('next').textContent = nextLabel;
  el('next').hidden = !running;
  el('undo').disabled = !previous;
  document.title = clock + ' · ' + speaker + ' · 회의 타이머';
  if (miniUI) {
    miniUI.count.textContent = (state.index + 1) + ' / ' + state.count + '명';
    drawSpeakers(miniUI.slots, true);
    miniUI.clock.textContent = clock;
    miniUI.clock.classList.toggle('over', rem <= -15000);
    miniUI.message.textContent = barNotice || (closing ? countdown : over && !paused ? '시간 초과' : status);
    setIconButton(miniUI.run, runLabel, running ? 'pause' : 'play');
    setIconButton(miniUI.next, nextLabel, nextLabel === '종료' ? 'stop' : 'skip');
    miniUI.next.disabled = !running;
    miniUI.undo.disabled = !previous;
    miniUI.fill.style.width = progress;
  }
}
el('run').onclick = () => toggle();
el('next').onclick = () => advance();
el('undo').onclick = undo;
const settings = el('settings');
function proposedEnd() {
  const value = el('endInput').value;
  if (!value || value === hour(state.end)) return state.end;
  const [hours, minutes] = value.split(':').map(Number);
  const date = new Date();
  date.setHours(hours, minutes, 0, 0);
  if (date.getTime() <= Date.now()) date.setDate(date.getDate() + 1);
  return date.getTime();
}
function updateSettingsHint() {
  const end = proposedEnd();
  const tomorrow = new Date(end).toDateString() !== new Date().toDateString() && end > Date.now();
  el('endLabel').textContent = tomorrow ? '회의 종료 시각 · 다음 날' : '회의 종료 시각';
  el('settingHint').textContent = '종료 시각이나 인원을 바꿔 저장하면 새 회의가 시작됩니다.';
}
el('settingsForm').oninput = updateSettingsHint;
el('edit').onclick = () => {
  el('endInput').value = hour(state.end);
  el('countInput').value = state.count;
  updateSettingsHint();
  settings.showModal();
};
el('cancel').onclick = () => settings.close();
el('settingsForm').onsubmit = event => {
  event.preventDefault();
  const now = Date.now();
  const count = el('countInput').valueAsNumber;
  const end = proposedEnd();
  if (end !== state.end || count !== state.count) {
    if (end - now < count * minute) {
      el('settingHint').textContent = '한 사람당 최소 1분이 필요합니다. 인원을 줄이거나 종료 시각을 늦춰 주세요.';
      return;
    }
    if (state.budget !== null && !confirm('진행 중인 회의를 끝내고 새 설정으로 시작할까요?')) return;
    state = meeting(count, end);
    previous = null;
    notify('');
    save();
  }
  settings.close();
};
// Only the dedicated extension popup belongs to the timer. A regular browser
// window can contain other tabs and must stay under the user's control.
const owner = extensionWindow ? chrome.windows.getCurrent() : Promise.resolve(null);
let transition = Promise.resolve();
async function openBar() {
  const button = el('mini');
  if (button.disabled) return;
  if (mini && !mini.closed) { mini.focus(); return; }
  button.disabled = true;
  let host;
  try {
    const width = window.innerWidth;
    // Some Windows configurations include the system title bar in the requested height.
    const height = (width < 520 ? 88 : 58) + Math.max(56, window.outerHeight - window.innerHeight);
    host = window.documentPictureInPicture
      ? await documentPictureInPicture.requestWindow({width, height, disallowReturnToOpener: true})
      : window.open('', 'meeting-timer-bar', 'popup,width=' + width + ',height=' + height);
    if (!host) throw new Error('Popup blocked');
    mini = host;
    const doc = host.document;
    doc.title = '발표 막대';
    doc.documentElement.lang = 'ko';
    doc.documentElement.dataset.theme = document.documentElement.dataset.theme;
    const css = doc.createElement('link');
    css.rel = 'stylesheet';
    css.href = document.querySelector('link[rel="stylesheet"]').href;
    doc.head.append(css);
    doc.body.replaceChildren(doc.importNode(el('barTemplate').content, true));
    const action = name => doc.querySelector('[data-action="' + name + '"]');
    miniUI = {
      run: action('run'), next: action('next'), undo: action('undo'),
      slots: doc.querySelector('.slots'), count: doc.querySelector('.count'),
      clock: doc.querySelector('.miniClock'), message: doc.querySelector('.message'), fill: doc.querySelector('.track i')
    };
    miniUI.run.onclick = () => toggle(host);
    miniUI.next.onclick = () => advance(host);
    miniUI.undo.onclick = undo;
    setIconButton(miniUI.undo, '되돌리기', 'undo');
    const back = action('back');
    setIconButton(back, '기본 창으로 돌아가기', 'back');
    back.onclick = () => host.close();
    doc.addEventListener('keydown', shortcuts);
    doc.querySelector('.miniBar').ondblclick = event => {
      if (!event.target.closest('button')) host.close();
    };
    let previousWindowState;
    host.addEventListener('pagehide', () => {
      host.clearInterval(tick);
      miniUI = mini = null;
      tick = window.setInterval(render, 250);
      transition = transition.then(async () => {
        const popup = await owner;
        if (previousWindowState) {
          await chrome.windows.update(popup.id, {state: previousWindowState});
          await chrome.windows.update(popup.id, {focused: true});
        }
      }).catch(() => {}).finally(() => { button.disabled = false; });
      render();
    }, {once: true});
    window.clearInterval(tick);
    tick = host.setInterval(render, 250);
    render();
    transition = transition.then(async () => {
      const popup = await owner;
      if (popup?.type !== 'popup' || host.closed) return;
      const current = await chrome.windows.get(popup.id);
      if (host.closed) return;
      previousWindowState = current.state === 'maximized' ? 'maximized' : 'normal';
      await chrome.windows.update(popup.id, {state: 'minimized'});
    });
    await transition;
  } catch {
    if (host && !host.closed) host.close();
    transition = Promise.resolve();
    notify('발표 막대를 열 수 없습니다. 타이머 창에서 다시 시도해 주세요.');
  } finally {
    if (!mini) button.disabled = false;
  }
}
function shortcuts(event) {
  if (settings.open || event.repeat || event.altKey || event.metaKey || event.shiftKey ||
      event.target.closest?.('input, textarea, select')) return;
  const key = event.key.toLowerCase();
  if (event.ctrlKey && key !== 'z') return;
  if (key === 'b' || (key === 'escape' && mini)) mini ? mini.close() : openBar();
  else if (key === ' ') toggle(mini || window);
  else if (key === 'n' || key === 'arrowright') advance(mini || window);
  else if (key === 'z' && event.ctrlKey) undo();
  else return;
  event.preventDefault();
}
document.addEventListener('keydown', shortcuts);
el('mini').onclick = openBar;
if (extensionWindow) {
  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (message?.action !== 'return-to-timer' || sender.id !== chrome.runtime.id) return;
    owner.then(popup => {
      if (popup.id === message.windowId && mini && !mini.closed) mini.close();
      reply(true);
    });
    return true;
  });
}
render();
