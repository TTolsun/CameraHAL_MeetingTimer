'use strict';
const extensionWindow = location.protocol === 'chrome-extension:';

const el = id => document.getElementById(id);
const sessionKey = 'meeting-timer.v1';
const wrapKey = 'timer-wrap-minutes';
let state = meeting(6, nextHour(Date.now()));
let previous = null;
let beforeWrap = null;
let speakerChoice = null;
try {
  const preference = Number(localStorage.getItem(wrapKey));
  if (validWrapMinutes(preference)) state = meeting(state.count, state.end, preference);
  const oldKey = Object.keys(sessionStorage).find(key => key.endsWith('.web-timer.v1'));
  const key = sessionStorage.getItem(sessionKey) !== null ? sessionKey : oldKey;
  const saved = key && JSON.parse(sessionStorage.getItem(key));
  if (saved && valid(saved.state)) {
    state = restoreMeeting(saved.state);
    previous = valid(saved.previous) ? restoreMeeting(saved.previous) : null;
    beforeWrap = valid(saved.beforeWrap) ? restoreMeeting(saved.beforeWrap) : null;
    if (key !== sessionKey) {
      sessionStorage.setItem(sessionKey, JSON.stringify({state, previous, beforeWrap}));
      sessionStorage.removeItem(key);
    }
  }
} catch {}
function save() {
  try { sessionStorage.setItem(sessionKey, JSON.stringify({state, previous, beforeWrap})); } catch {}
  render();
}
function confirmSpeakerStart(host, index, start) {
  const now = Date.now();
  const options = wrapOptions(state, now, index);
  if (now >= state.end && host === window) {
    if (host.confirm('The meeting end time has passed. Track the next speaker in overtime?')) start(state.reserve);
    return;
  }
  if (!options && now < state.end) {
    start(state.reserve);
    return;
  }
  const doc = host.document;
  const dialog = doc.importNode(el('speakerChoiceTemplate').content, true).firstElementChild;
  const body = dialog.querySelector('p');
  const keep = dialog.querySelector('[value="keep"]');
  const use = dialog.querySelector('[value="use"]');
  if (options) {
    const count = state.count - index;
    body.textContent = count + ' remaining · Estimated time';
    dialog.querySelector('.speakerChoiceKeep').textContent = 'Keep: ' + duration(options.keepShare) +
      ' each · ' + duration(options.keepReserve) + ' wrap-up';
    dialog.querySelector('.speakerChoiceUse').textContent = 'Use: ' + duration(options.useShare) +
      ' each · ' + duration(options.reserve) + ' wrap-up';
  } else {
    body.textContent = 'The meeting end time has passed. Track the next speaker in overtime?';
    keep.hidden = true;
    use.textContent = 'Track overtime';
  }
  dialog.addEventListener('close', () => {
    const choice = dialog.returnValue;
    dialog.remove();
    if (speakerChoice !== dialog) return;
    speakerChoice = null;
    if (choice !== 'keep' && choice !== 'use') return;
    if (options && Date.now() >= state.end) {
      confirmSpeakerStart(host, index, start);
      return;
    }
    if (choice === 'keep') start(state.reserve);
    if (choice === 'use') start(wrapOptions(state, Date.now(), index)?.reserve ?? state.reserve);
  }, {once: true});
  doc.body.append(dialog);
  dialog.showModal();
  speakerChoice = dialog;
}
function startCurrent(reserve) {
  const now = Date.now();
  state.reserve = reserve;
  startSpeaker(state, now);
  notify('');
  save();
}
function toggle(host = window) {
  if (speakerChoice || state.wrapStart !== null) return;
  const now = Date.now();
  if (state.started !== null) {
    state.elapsed += Math.max(0, now - state.started);
    state.started = null;
  } else {
    if (state.budget === null) confirmSpeakerStart(host, state.index, startCurrent);
    else startCurrent(state.reserve);
    return;
  }
  notify('');
  save();
}
function advance(host = window) {
  if (speakerChoice) return;
  const now = Date.now();
  if (state.wrapStart !== null) {
    previous = {...state};
    finishMeeting(now);
    return;
  }
  if (state.started === null) return;
  const last = state.index + 1 === state.count;
  if (!last) {
    confirmSpeakerStart(host, state.index + 1, reserve => {
      previous = {...state};
      state.index++;
      state.elapsed = 0;
      state.budget = null;
      startCurrent(reserve);
    });
    return;
  }
  previous = {...state};
  if (state.wrapMinutes > 0) {
    beforeWrap = previous;
    state.elapsed += Math.max(0, now - state.started);
    state.started = null;
    state.wrapStart = now;
    notify('');
    save();
  } else finishMeeting(now);
}
function finishMeeting(now) {
  const wasWrap = state.wrapStart !== null;
  state = meeting(state.count, nextHour(now), state.wrapMinutes);
  notify(wasWrap ? 'Meeting ended. Use Undo to return to wrap-up.' :
    'Meeting ended. Use Undo to return to the last speaker.', 'Meeting ended');
  save();
}
function undo() {
  if (speakerChoice || !previous) return;
  state = previous;
  previous = state.wrapStart !== null ? beforeWrap : null;
  if (state.wrapStart === null) beforeWrap = null;
  notify(state.wrapStart !== null ? 'Returned to wrap-up.' : 'Returned to the previous speaker.');
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
  setIconButton(el('theme'), dark ? 'Switch to light theme' : 'Switch to dark theme', dark ? 'sun' : 'moon');
  try { localStorage.setItem('timer-theme', theme); } catch {}
}
let initialTheme = 'light';
try { if (localStorage.getItem('timer-theme') === 'dark') initialTheme = 'dark'; } catch {}
chooseTheme(initialTheme);
el('theme').onclick = () => chooseTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
setIconButton(el('undo'), 'Undo', 'undo');
setIconButton(el('edit'), 'Meeting settings', 'settings');

function drawSpeakers(row) {
  const key = state.index + '/' + state.count;
  if (row.dataset.speakers === key) return;
  row.dataset.speakers = key;
  row.replaceChildren();
  for (let i = 0; i < state.count; i++) {
    const mark = document.createElement('i');
    if (state.index === i) {
      mark.className = 'current';
      mark.setAttribute('aria-current', 'step');
    } else if (i < state.index) mark.className = 'done';
    row.append(mark);
  }
}
function render() {
  const now = Date.now();
  const rem = remaining(state, now);
  const wrapping = state.wrapStart !== null;
  const budget = wrapping ? Math.max(0, state.end - state.wrapStart) : state.budget ?? allocation(state, now);
  const running = state.started !== null;
  const idle = state.budget === null && !wrapping;
  const paused = !idle && !running && !wrapping;
  const over = !idle && rem <= 0;
  const status = paused ? 'Paused' : running || wrapping ? 'Running' : 'Ready';
  const clock = duration(rem);
  const speaker = wrapping ? 'Wrap-up' : 'Speaker ' + (state.index + 1);
  const runLabel = running ? 'Pause' : paused ? 'Resume' : 'Start';
  const nextLabel = wrapping ? 'Finish' : state.index + 1 < state.count ? 'Next' :
    state.wrapMinutes ? 'Start wrap-up' : 'Finish';
  const progress = (budget ? Math.max(0, Math.min(1, 1 - rem / budget)) : Number(over)) * 100 + '%';
  const closing = running && rem > 0 && rem <= Math.max(minute, budget * .3);
  const seconds = Math.ceil(rem / 1000);
  const countdown = [Math.floor(seconds / 60) && Math.floor(seconds / 60) + ' min', seconds % 60 && seconds % 60 + ' sec'].filter(Boolean).join(' ') + ' left';
  el('now').textContent = hour(now);
  const delta = state.plan == null ? 0 : budget - state.plan;
  el('delta').hidden = wrapping || delta === 0;
  if (!wrapping && delta !== 0) {
    el('deltaValue').textContent = (delta < 0 ? '−' : '+') + duration(Math.abs(delta));
    el('delta').dataset.sign = delta < 0 ? 'minus' : 'plus';
  }
  el('speaker').textContent = speaker;
  el('clock').textContent = clock;
  el('clock').style.setProperty('--clock-length', clock.length);
  el('clock').classList.toggle('over', rem <= -15000);
  el('status').textContent = over ? (paused ? 'Overtime · Paused' : 'Overtime') : status;
  el('budget').textContent = wrapping ? (rem > 0 ? countdown : 'Meeting end time reached') :
    closing ? countdown : over || paused ? '' :
    idle && !budget && now >= state.end ? 'Press Start to track overtime' :
    'Allocated ' + duration(budget) + (idle ? ' · Press Start' : '');
  el('deadline').textContent = hour(state.end);
  el('left').textContent = now >= state.end ? 'End time reached' : Math.ceil((state.end - now) / minute) + ' min left';
  el('left').classList.toggle('warn', now >= state.end);
  el('segments').hidden = wrapping;
  if (!wrapping) drawSpeakers(el('segments'));
  el('segments').style.setProperty('--progress', progress);
  el('run').textContent = runLabel;
  el('run').hidden = wrapping;
  el('next').textContent = nextLabel;
  el('next').classList.toggle('start-wrap', nextLabel === 'Start wrap-up');
  el('next').hidden = !running && !wrapping;
  el('undo').disabled = !previous;
  document.title = clock + ' · ' + speaker + ' · Time per Turn';
  if (miniUI) {
    miniUI.count.textContent = wrapping ? 'Wrap-up' : (state.index + 1) + ' / ' + state.count;
    miniUI.clock.textContent = clock;
    miniUI.clock.classList.toggle('over', rem <= -15000);
    miniUI.clock.style.setProperty('--clock-length', clock.length);
    const message = barNotice || (wrapping && !over ? 'Ends ' + hour(state.end) :
      paused ? 'Paused' : over ? 'Overtime' : nextLabel === 'Start wrap-up' && running ? 'Next: wrap-up' : '');
    if (miniUI.message.textContent !== message) miniUI.message.textContent = message;
    setIconButton(miniUI.run, runLabel, running ? 'pause' : 'play');
    miniUI.run.hidden = wrapping;
    setIconButton(miniUI.next, nextLabel, nextLabel === 'Finish' ? 'stop' : nextLabel === 'Start wrap-up' ? 'wrap' : 'skip');
    miniUI.next.disabled = !running && !wrapping;
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
  el('endLabel').textContent = tomorrow ? 'End time (tomorrow)' : 'Meeting end time';
  const wrap = el('wrapInput').valueAsNumber;
  const count = el('countInput').valueAsNumber;
  el('settingHint').textContent = wrap > 0 && end - Date.now() < (count + wrap) * minute
    ? 'This schedule may require shorter turns or using some wrap-up time.'
    : 'Changing the end time, speakers, or wrap-up starts a new meeting.';
}
el('settingsForm').oninput = updateSettingsHint;
el('edit').onclick = () => {
  if (speakerChoice) return;
  el('endInput').value = hour(state.end);
  el('countInput').value = state.count;
  el('wrapInput').value = state.wrapMinutes;
  updateSettingsHint();
  settings.showModal();
};
el('cancel').onclick = () => settings.close();
el('settingsForm').onsubmit = event => {
  event.preventDefault();
  if (speakerChoice) return;
  const now = Date.now();
  const count = el('countInput').valueAsNumber;
  const wrap = el('wrapInput').valueAsNumber;
  const end = proposedEnd();
  if (end !== state.end || count !== state.count || wrap !== state.wrapMinutes) {
    if (end - now < count * minute) {
      el('settingHint').textContent = 'Allow at least 1 min per speaker. Choose fewer speakers or a later end time.';
      return;
    }
    if (state.budget !== null && !confirm('End this meeting and start a new one with these settings?')) return;
    state = meeting(count, end, wrap);
    previous = null;
    beforeWrap = null;
    try { localStorage.setItem(wrapKey, String(wrap)); } catch {}
    notify('');
    save();
  }
  settings.close();
};
// Only the dedicated extension popup belongs to the timer. A regular browser
// window can contain other tabs and must stay under the user's control.
const owner = extensionWindow ? chrome.windows.getCurrent() : Promise.resolve(null);
let normalTimerSize = timerBounds;
const resetSize = el('resetSize');
setIconButton(resetSize, 'Restore default size', 'reset-size');
owner.then(popup => { resetSize.hidden = popup?.type !== 'popup'; }).catch(() => {});
resetSize.onclick = async () => {
  if (resetSize.disabled || resetSize.hidden) return;
  resetSize.disabled = true;
  let popup;
  try {
    popup = await chrome.windows.getCurrent();
    if (popup?.type !== 'popup' || popup.id !== (await owner)?.id) return;
    try {
      if (popup.state !== 'normal') await chrome.windows.update(popup.id, {state: 'normal'});
      await chrome.windows.update(popup.id, timerBounds);
    } catch (apiError) {
      try {
        window.resizeTo(timerBounds.width, timerBounds.height);
        for (let attempt = 0; attempt < 10; attempt++) {
          if (Math.abs(window.outerWidth - timerBounds.width) <= 2 &&
              Math.abs(window.outerHeight - timerBounds.height) <= 2) return;
          await new Promise(resolve => window.setTimeout(resolve, 50));
        }
      } catch (resizeError) {
        console.error('Could not resize the timer popup using Window.resizeTo.', resizeError);
      }
      throw apiError;
    }
  } catch (error) {
    console.error('Could not restore the timer popup to its default bounds.', {windowId: popup?.id, bounds: timerBounds}, error);
    notify('Could not restore the window size.');
  } finally {
    resetSize.disabled = false;
  }
};
let transition = Promise.resolve();
let barBusy = false;
let timerPageClosing = false;
window.addEventListener('pagehide', () => { timerPageClosing = true; });
window.addEventListener('pageshow', () => { timerPageClosing = false; });
// A minimized opener can see stale DOM dimensions for its separate Chrome popup.
async function bindPresenterPopup(host, reset, showForSize, anchor, rememberPosition) {
  const opener = await chrome.tabs.getCurrent();
  if (!opener || host.closed) return;
  const tabs = await chrome.tabs.query({active: true, windowType: 'popup'});
  const bar = tabs.find(tab => tab.openerTabId === opener.id);
  if (!bar || host.closed) return;
  let initial;
  const changed = popup => {
    if (host.closed || popup.id !== bar.windowId) return;
    if (popup.state === 'maximized') {
      miniUI.returnToTimer();
      return;
    }
    if (popup.state === 'normal') {
      rememberPosition({left: popup.left, top: popup.top});
      if (initial) showForSize(popup.width, popup.height, initial.width, initial.height);
    }
  };
  chrome.windows.onBoundsChanged.addListener(changed);
  host.addEventListener('pagehide', () => chrome.windows.onBoundsChanged.removeListener(changed), {once: true});
  initial = await chrome.windows.get(bar.windowId);
  changed(initial);
  if (host.closed || initial.state !== 'normal') return;
  // Chrome can clamp window.open coordinates to the opener's current monitor.
  if (anchor && (initial.left !== anchor.left || initial.top !== anchor.top)) {
    changed(await chrome.windows.update(bar.windowId, {left: anchor.left, top: anchor.top}));
  }
  reset.onclick = () => chrome.windows.update(bar.windowId, {width: initial.width, height: initial.height});
}
async function openBar(anchor = null) {
  if (barBusy) return;
  if (mini && !mini.closed) { mini.focus(); return; }
  barBusy = true;
  let host;
  try {
    const width = 328;
    // The native minimize command does not grant the gesture required by Document PiP.
    const pictureInPicture = !anchor && window.documentPictureInPicture;
    const position = anchor ? ',left=' + anchor.left + ',top=' + anchor.top : '';
    host = pictureInPicture
      ? await pictureInPicture.requestWindow({
        width, height: 92, disallowReturnToOpener: true, preferInitialWindowPlacement: true
      })
      : window.open('', 'meeting-timer-bar',
        'popup,width=' + width + ',height=' + (Math.max(88, window.outerHeight - window.innerHeight) + 40) + position);
    if (!host) throw new Error('Popup blocked');
    mini = host;
    const doc = host.document;
    doc.title = 'Presenter bar';
    doc.documentElement.lang = 'en';
    doc.documentElement.dataset.theme = document.documentElement.dataset.theme;
    const css = doc.createElement('link');
    css.rel = 'stylesheet';
    css.href = document.querySelector('link[rel="stylesheet"]').href;
    doc.head.append(css);
    doc.body.replaceChildren(doc.importNode(el('barTemplate').content, true));
    const action = name => doc.querySelector('[data-action="' + name + '"]');
    let returning = false;
    miniUI = {
      returnToTimer() {
        returning = true;
        host.close();
      },
      run: action('run'), next: action('next'), undo: action('undo'),
      count: doc.querySelector('.count'),
      clock: doc.querySelector('.miniClock'), message: doc.querySelector('.message'), fill: doc.querySelector('.track i')
    };
    miniUI.run.onclick = () => toggle(host);
    miniUI.next.onclick = () => advance(host);
    miniUI.undo.onclick = undo;
    setIconButton(miniUI.undo, 'Undo', 'undo');
    let barPosition = anchor;
    const reset = action('reset');
    // Document Picture-in-Picture accepted user-initiated resizing starting in Chrome 121.
    const chromeMajor = Number(navigator.userAgent.match(/\bChrome\/(\d+)/)?.[1] ?? Infinity);
    if (!pictureInPicture || chromeMajor >= 121) {
      // Older PiP versions can open at the last used bounds. Use their frame
      // insets to derive a compact target even when the window reopens large.
      const defaults = pictureInPicture && chromeMajor < 130
        ? {width: width + host.outerWidth - host.innerWidth, height: 38 + host.outerHeight - host.innerHeight}
        : {width: host.outerWidth, height: host.outerHeight};
      const root = doc.documentElement;
      const defaultViewport = {width: root.clientWidth, height: root.clientHeight};
      setIconButton(reset, 'Restore default size', 'reset-size');
      const showForSize = (w, h, defaultW, defaultH) => {
        const atDefault = Math.abs(w - defaultW) <= 2 && Math.abs(h - defaultH) <= 2;
        if (atDefault && doc.activeElement === reset) doc.querySelector('.controls button:not([hidden]):enabled')?.focus();
        reset.hidden = atDefault;
      };
      reset.onclick = () => host.resizeTo(defaults.width, defaults.height);
      if (!pictureInPicture && extensionWindow) {
        reset.hidden = true;
        bindPresenterPopup(host, reset, showForSize, anchor, position => { barPosition = position; })
          .catch(error => console.error('Presenter bar placement:', error));
      } else {
        const updateReset = () => pictureInPicture
          ? showForSize(host.outerWidth, host.outerHeight, defaults.width, defaults.height)
          : showForSize(root.clientWidth, root.clientHeight, defaultViewport.width, defaultViewport.height);
        host.addEventListener('resize', updateReset);
        updateReset();
      }
    }
    doc.addEventListener('keydown', shortcuts);
    doc.querySelector('.miniBar').ondblclick = event => {
      if (!event.target.closest('button')) miniUI.returnToTimer();
    };
    let restorePopup = !!anchor;
    let timerSize = normalTimerSize;
    host.addEventListener('pagehide', () => {
      const position = barPosition || {left: host.screenX, top: host.screenY};
      const {availLeft, availTop, availWidth, availHeight} = host.screen;
      if (speakerChoice?.ownerDocument === doc) speakerChoice = null;
      host.clearInterval(tick);
      miniUI = mini = null;
      tick = window.setInterval(render, 250);
      transition = transition.then(async () => {
        if (timerPageClosing) return;
        if (!returning) {
          if (extensionWindow) {
            const tab = await chrome.tabs.getCurrent();
            if (tab) await chrome.tabs.remove(tab.id);
          } else window.close();
          return;
        }
        const popup = await owner;
        if (restorePopup) {
          await chrome.windows.update(popup.id, {state: 'normal'});
          const bounds = {state: 'normal', ...timerSize, left: position.left, top: position.top, focused: true};
          try {
            await chrome.windows.update(popup.id, bounds);
          } catch {
            // Chrome rejects a placement with too little of the larger timer on screen.
            bounds.left = Math.max(availLeft, Math.min(bounds.left, availLeft + availWidth - bounds.width));
            bounds.top = Math.max(availTop, Math.min(bounds.top, availTop + availHeight - bounds.height));
            await chrome.windows.update(popup.id, bounds);
          }
        }
      }).catch(() => {}).finally(() => { barBusy = false; });
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
      restorePopup = true;
      if (current.state === 'normal') timerSize = {width: current.width, height: current.height};
      if (current.state !== 'minimized') await chrome.windows.update(popup.id, {state: 'minimized'});
    });
    await transition;
  } catch {
    if (host && !host.closed) {
      if (miniUI) miniUI.returnToTimer();
      else host.close();
    }
    transition = Promise.resolve();
    if (anchor && !host) {
      const popup = await owner;
      await chrome.windows.update(popup.id, {state: anchor.state === 'maximized' ? 'maximized' : 'normal', focused: true}).catch(() => {});
    }
    notify('Could not open the presenter bar. Try again from the timer window.');
  } finally {
    if (!mini) barBusy = false;
  }
}
function shortcuts(event) {
  if (settings.open || speakerChoice ||
      event.repeat || event.altKey || event.metaKey || event.shiftKey ||
      event.target.closest?.('input, textarea, select')) return;
  const key = event.key.toLowerCase();
  if (event.ctrlKey && key !== 'z') return;
  if (key === 'b' || (key === 'escape' && mini)) miniUI ? miniUI.returnToTimer() : openBar();
  else if (key === ' ') toggle(mini || window);
  else if (key === 'n' || key === 'arrowright') advance(mini || window);
  else if (key === 'z' && event.ctrlKey) undo();
  else return;
  event.preventDefault();
}
document.addEventListener('keydown', shortcuts);
if (extensionWindow) {
  owner.then(popup => {
    if (popup.type !== 'popup') return;
    let lastBounds = popup;
    if (popup.state === 'normal') normalTimerSize = {width: popup.width, height: popup.height};
    async function checkMinimized() {
      if (mini || barBusy || settings.open || speakerChoice) return;
      const current = await chrome.windows.get(popup.id).catch(() => null);
      if (!current) return;
      if (current.state === 'minimized') {
        await openBar(lastBounds);
      }
    }
    chrome.windows.onBoundsChanged.addListener(changed => {
      if (changed.id !== popup.id) return;
      if (changed.state === 'normal' && !barBusy) normalTimerSize = {width: changed.width, height: changed.height};
      if (changed.state === 'minimized') void checkMinimized();
      else if (changed.state === 'normal' || changed.state === 'maximized') lastBounds = changed;
    });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) void checkMinimized();
    });
  });
  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (message?.action !== 'return-to-timer' || sender.id !== chrome.runtime.id) return;
    owner.then(popup => {
      if (popup.id === message.windowId && mini && !mini.closed) miniUI.returnToTimer();
      reply(true);
    });
    return true;
  });
}
render();
