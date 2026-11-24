// Run with node --test and CHROME_FOR_TESTING set to the testing browser's executable.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import test from 'node:test';

async function until(check) {
  for (let i = 0; i < 100; i++) {
    const result = await check();
    if (result) return result;
    await delay(100);
  }
  throw new Error('Timed out waiting for ' + check);
}

test('presenter bar replaces the visible popup and restores the same meeting', {
  skip: !process.env.CHROME_FOR_TESTING, timeout: 90000
}, async t => {
  const extension = process.env.TIMER_EXTENSION_DIR || fileURLToPath(new URL('../chrome-extension', import.meta.url));
  const profile = await mkdtemp(join(tmpdir(), 'timer-pip-profile-'));
  const browser = spawn(process.env.CHROME_FOR_TESTING, [
    '--user-data-dir=' + profile, '--remote-debugging-port=0', '--no-first-run',
    '--no-default-browser-check', '--disable-sync', '--load-extension=' + extension,
    '--disable-extensions-except=' + extension, 'about:blank'
  ], {windowsHide: true, stdio: 'ignore'});
  const exited = new Promise(resolve => browser.once('exit', resolve));
  let socket;
  t.after(async () => {
    socket?.close();
    browser.kill();
    await exited;
    await rm(profile, {recursive: true, force: true, maxRetries: 5, retryDelay: 300});
  });
  const portFile = await until(() => readFile(join(profile, 'DevToolsActivePort'), 'utf8').catch(() => ''));
  const [port, path] = portFile.trim().split(/\r?\n/);
  socket = new WebSocket('ws://127.0.0.1:' + port + path);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let id = 0;
  const pending = new Map();
  const dialogAnswers = [];
  let dialogHandled = Promise.resolve();
  socket.onmessage = ({data}) => {
    const message = JSON.parse(data);
    if (message.method === 'Page.javascriptDialogOpening') {
      const accept = dialogAnswers.shift() ?? false;
      dialogHandled = call('Page.handleJavaScriptDialog', {accept}, message.sessionId);
    }
    if (!pending.has(message.id)) return;
    const {resolve, reject} = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result);
  };
  function call(method, params, sessionId) {
    return new Promise((resolve, reject) => {
      pending.set(++id, {resolve, reject});
      socket.send(JSON.stringify({id, method, params, sessionId}));
    });
  }
  async function attach(suffix) {
    const target = await until(async () => (await call('Target.getTargets', {})).targetInfos
      .find(info => info.url.startsWith('chrome-extension://') && info.url.endsWith(suffix)));
    return (await call('Target.attachToTarget', {targetId: target.targetId, flatten: true})).sessionId;
  }
  async function evaluate(session, expression, userGesture = true) {
    const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true, userGesture}, session);
    assert.ok(!result.exceptionDetails, result.exceptionDetails?.exception?.description || expression);
    return result.result.value;
  }
  const worker = await attach('/launcher.js');
  await until(() => evaluate(worker, "typeof openTimer === 'function'"));
  await evaluate(worker, 'openTimer()');
  const page = await attach('/index.html');
  await call('Page.enable', {}, page);
  const run = expression => evaluate(page, expression);
  const clickButton = selector => run(`document.querySelector(${JSON.stringify(selector)}).click()`);
  await until(() => run("document.readyState === 'complete' && !!document.querySelector('#run').onclick"));
  async function click(selector) {
    const hit = await run(`(() => {
      const element = document.querySelector(${JSON.stringify(selector)});
      const box = element.getBoundingClientRect();
      const x = box.x + box.width / 2, y = box.y + box.height / 2;
      const target = document.elementFromPoint(x, y);
      if (element.disabled || !element.contains(target)) {
        return {hidden: element.hidden, disabled: element.disabled, target: target?.outerHTML.slice(0, 150),
          box: box.toJSON(), viewport: [innerWidth, innerHeight]};
      }
      return {point: {x, y}};
    })()`);
    assert.ok(hit.point, selector + ' must be visible, enabled and reachable: ' + JSON.stringify(hit));
    for (const type of ['mousePressed', 'mouseReleased']) {
      await call('Input.dispatchMouseEvent', {type, ...hit.point, button: 'left', clickCount: 1}, page);
    }
  }
  async function clickConfirm(selector, accept) {
    dialogAnswers.push(accept);
    await clickButton(selector);
    await until(() => dialogAnswers.length === 0);
    await dialogHandled;
  }
  async function barClick(action) {
    const hit = await run(`(() => {
      const doc = mini.document, button = doc.querySelector('[data-action="${action}"]');
      const box = button.getBoundingClientRect();
      const target = doc.elementFromPoint(box.x + box.width/2, box.y + box.height/2);
      if (button.disabled || !button.contains(target)) return {disabled: button.disabled, target: target?.outerHTML, box: box.toJSON(), size:[mini.innerWidth, mini.innerHeight]};
      button.click(); return true;
    })()`);
    assert.equal(hit, true, action + ' must be reachable in the bar: ' + JSON.stringify(hit));
  }
  const viewport = await run('({height: innerHeight, content: document.documentElement.scrollHeight})');
  assert.ok(viewport.content <= viewport.height, 'Default timer must fit: ' + JSON.stringify(viewport));
  async function assertActionRow() {
    const layout = await run(`(() => {
      const boxes = Array.from(document.querySelectorAll('.actions button'), button => button.getBoundingClientRect());
      return {singleRow: boxes.every(box => Math.abs((box.top + box.bottom) / 2 - (boxes[0].top + boxes[0].bottom) / 2) < 1),
        width: innerWidth, height: innerHeight, right: boxes.at(-1).right, bottom: Math.max(...boxes.map(box => box.bottom))};
    })()`);
    assert.ok(layout.singleRow && layout.right <= layout.width && layout.bottom <= layout.height,
      'All timer actions must fit on one row: ' + JSON.stringify(layout));
  }
  await assertActionRow();
  async function assertStageFits() {
    const layout = await run(`(() => {
      const footer = document.querySelector('.actions').getBoundingClientRect();
      const frame = document.querySelector('.clockFrame').getBoundingClientRect();
      const clock = el('clock').getBoundingClientRect();
      const segments = el('segments').getBoundingClientRect();
      return {footerTop: footer.top, segmentsBottom: segments.bottom, frameTop: frame.top, frameBottom: frame.bottom,
        clockTop: clock.top, clockBottom: clock.bottom, clockLeft: clock.left, clockRight: clock.right, width: innerWidth};
    })()`);
    assert.ok(layout.segmentsBottom <= layout.footerTop && layout.clockTop >= layout.frameTop &&
      layout.clockBottom <= layout.frameBottom && layout.clockLeft >= 0 && layout.clockRight <= layout.width,
      'The clock and progress segments must fit above the actions: ' + JSON.stringify(layout));
  }
  await assertStageFits();
  async function assertIcon(selector, label, icon, doc = 'document') {
    assert.deepEqual(await run(`(() => {
      const button = ${doc}.querySelector(${JSON.stringify(selector)});
      const svg = button.querySelector('svg');
      return [button.getAttribute('aria-label'), svg?.dataset.icon, svg?.getAttribute('aria-hidden')];
    })()`), [label, icon, 'true']);
  }
  assert.equal(await run("el('mini')"), null);
  await assertIcon('#edit', 'Meeting settings', 'settings');
  async function assertSettingsControls() {
    assert.equal(await run('document.activeElement?.id'), 'endInput', 'Settings must open with the end-time input focused');
    const layout = await run(`(() => {
      const dialog = el('settings');
      const bounds = dialog.getBoundingClientRect();
      const buttons = Array.from(dialog.querySelectorAll('.dialogActions button'), button => {
        const box = button.getBoundingClientRect();
        const hit = document.elementFromPoint((box.left + box.right) / 2, (box.top + box.bottom) / 2);
        return {name: button.textContent, top: box.top, bottom: box.bottom, hit: button.contains(hit)};
      });
      return {height: innerHeight, dialogBottom: bounds.bottom, clientHeight: dialog.clientHeight,
        scrollHeight: dialog.scrollHeight, buttons};
    })()`);
    assert.ok(layout.buttons.every(button => button.hit && button.top >= 0 &&
      button.bottom <= Math.min(layout.height, layout.dialogBottom)),
      'Settings buttons must be fully reachable without scrolling: ' + JSON.stringify(layout));
  }
  await click('#edit');
  await assertSettingsControls();
  await assertIcon('#theme', 'Switch to dark theme', 'moon');
  await click('#theme');
  assert.equal(await run("localStorage.getItem('timer-theme')"), 'dark');
  await call('Page.reload', {}, page);
  await until(() => run("document.readyState === 'complete' && document.documentElement.dataset.theme === 'dark'"));
  await click('#edit');
  await assertIcon('#theme', 'Switch to light theme', 'sun');
  await click('#theme');
  assert.equal(await run("document.documentElement.dataset.theme"), 'light');
  await run("el('countInput').value = 49");
  await click('#cancel');
  await click('#edit');
  assert.equal(await run("el('countInput').value"), '6');
  await run("el('countInput').value = 50; el('endInput').value = hour(Date.now() + 5 * minute)");
  await click('button[type=submit]');
  assert.ok(await run("settings.open && el('settingHint').textContent.includes('at least 1 min')"));
  await run("el('endInput').value = hour(Date.now() - minute); el('endInput').dispatchEvent(new Event('input', {bubbles:true}))");
  if (await run("new Date().getHours() + new Date().getMinutes() > 0")) {
    assert.ok(await run("el('endLabel').textContent.includes('tomorrow')"));
  }
  await run("el('countInput').value = 2; el('endInput').value = hour(Date.now() + 35 * minute)");
  await click('button[type=submit]');
  assert.ok(await run("!settings.open && el('segments').children.length === 2 && el('undo').disabled"));
  const undoX = await run("el('undo').getBoundingClientRect().x");
  assert.ok(await run("el('delta').hidden"));
  const deadlineX = await run("el('deadline').getBoundingClientRect().x");
  await click('#run');
  assert.equal(await run("el('undo').getBoundingClientRect().x"), undoX);
  assert.ok(await run("el('delta').hidden && state.plan === state.budget"));
  await until(() => run("Date.now() - state.started >= 1000"));
  await click('#next');
  assert.match(await run("el('delta').hidden ? '' : el('delta').textContent"), /^From plan \+\d+:\d{2}$/);
  assert.equal(await run("el('deadline').getBoundingClientRect().x"), deadlineX);
  assert.equal(await run("el('next').textContent"), 'Finish');
  await call('Input.dispatchKeyEvent', {type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32}, page);
  await call('Input.dispatchKeyEvent', {type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32}, page);
  assert.ok(await run("el('speaker').textContent === 'Speaker 2' && el('run').textContent === 'Resume'"));
  await click('#run');
  await click('#next');
  assert.ok(await run("el('notice').textContent.includes('Meeting ended') && el('next').hidden"));
  await assertStageFits();
  assert.ok(await run("el('delta').hidden"));
  await click('#undo');
  assert.equal(await run("el('speaker').textContent"), 'Speaker 2');
  if (process.env.TIMER_SCREENSHOT) {
    const shot = await call('Page.captureScreenshot', {format: 'png'}, page);
    await writeFile(process.env.TIMER_SCREENSHOT, Buffer.from(shot.data, 'base64'));
  }
  await click('#edit');
  await click('#theme');
  await click('#cancel');
  const popupId = await run('chrome.windows.getCurrent().then(w => w.id)');
  const popupState = () => evaluate(worker, 'chrome.windows.get(' + popupId + ').then(w => w.state)');
  const popupSize = () => evaluate(worker, 'chrome.windows.get(' + popupId + ').then(w => [w.width, w.height])');
  const initialPopupSize = await popupSize();
  const matchesSize = (actual, expected) => actual.every((value, axis) => Math.abs(value - expected[axis]) <= 2);
  await assertIcon('#resetSize', 'Restore default size', 'reset-size');
  const barReady = () => evaluate(page,
    "!!miniUI && !mini.closed && mini.getComputedStyle(mini.document.querySelector('.miniBar')).display === 'grid'", false);
  const pressBarShortcut = async () => {
    for (const type of ['keyDown', 'keyUp']) {
      await call('Input.dispatchKeyEvent', {type, key: 'b', code: 'KeyB', windowsVirtualKeyCode: 66}, page);
    }
  };
  const open = async () => {
    await pressBarShortcut();
    await until(async () => await popupState() === 'minimized' && await barReady());
    assert.ok(await run("!!documentPictureInPicture.window?.document.querySelector('.miniClock')"));
  };
  const restored = async () => {
    await until(async () => await popupState() === 'normal' && await run('!mini && !barBusy')).catch(async error => {
      throw new Error('Timer restore: ' + await popupState() + ', bar open/busy: ' + await run('[!!mini, barBusy]'), {cause: error});
    });
  };
  const presenterPopup = () => evaluate(worker, `chrome.windows.getAll().then(windows =>
    windows.find(w => w.type === 'popup' && w.id !== ${popupId}))`);
  const closeBarWindow = id => evaluate(worker, 'chrome.windows.remove(' + id + ')');
  const maximizeBar = id => evaluate(worker, 'chrome.windows.update(' + id + ', {state:"maximized"})');
  const leaveBar = () => run("mini.document.dispatchEvent(new mini.KeyboardEvent('keydown', {key:'Escape', bubbles:true}))");
  const turnBeforeMinimize = await run('JSON.stringify(state)');
  // A fresh timer page has no activation from an in-page click before minimization.
  await call('Page.reload', {}, page);
  await until(() => evaluate(page, "document.readyState === 'complete' && typeof barBusy === 'boolean' && !navigator.userActivation.isActive", false));
  for (const [left, top] of [[120, 90], [215, 150]]) {
    const placed = await evaluate(worker, 'chrome.windows.update(' + popupId + ', {left:' + left + ', top:' + top + '})');
    await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "minimized"})', false);
    await until(barReady);
    await until(() => evaluate(worker, `chrome.windows.getAll().then(windows => windows.some(w =>
      w.type === 'popup' && w.id !== ${popupId} && w.left === ${placed.left} && w.top === ${placed.top}))`));
    assert.equal(await run('miniUI.count.textContent'), '2 / 2');
    const bar = await presenterPopup();
    const moved = await evaluate(worker, 'chrome.windows.update(' + bar.id + ', {left:' + (left + 75) + ', top:' + (top + 55) + '})');
    await maximizeBar(bar.id);
    await restored();
    const original = await evaluate(worker, 'chrome.windows.get(' + popupId + ')');
    assert.ok(matchesSize([original.left, original.top], [moved.left, moved.top]), 'Maximizing the bar returns the timer to its last position');
    assert.ok(matchesSize([original.width, original.height], [placed.width, placed.height]),
      'Timer size after close: ' + [original.width, original.height] + ', before minimize: ' + [placed.width, placed.height]);
  }
  assert.equal(await run('JSON.stringify(state)'), turnBeforeMinimize);
  const beforeMaximize = await popupSize();
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "maximized"})');
  await until(async () => await popupState() === 'maximized' && (await popupSize())[0] > initialPopupSize[0]);
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "minimized"})', false);
  await until(barReady);
  await maximizeBar((await presenterPopup()).id);
  await restored();
  await until(async () => matchesSize(await popupSize(), beforeMaximize)).catch(async error => {
    throw new Error('Expected ' + beforeMaximize + ', restored ' + await popupSize(), {cause: error});
  });
  await open();
  const barSize = () => run('[mini.outerWidth, mini.outerHeight]');
  const initialBarSize = await barSize();
  const defaultBarSize = async () => matchesSize(await barSize(), initialBarSize);
  assert.ok(await run("mini.document.querySelector('[data-action=reset]').hidden"));
  async function assertBarLayout(windowWidth) {
    await until(() => run("mini.getComputedStyle(mini.document.querySelector('.miniBar')).display === 'grid'"));
    const layout = await run(`(() => {
      const doc = mini.document;
      const bar = doc.querySelector('.miniBar');
      const boxes = Array.from(bar.children).slice(0, 3).map(child => child.getBoundingClientRect());
      return {width: mini.innerWidth, height: mini.innerHeight, scrollWidth: doc.documentElement.scrollWidth,
        scrollHeight: doc.documentElement.scrollHeight,
        barHeight: bar.getBoundingClientRect().height, clockHeight: miniUI.clock.getBoundingClientRect().height,
        singleRow: boxes.every(box => Math.abs((box.top + box.bottom) / 2 - (boxes[0].top + boxes[0].bottom) / 2) < 1)};
    })()`);
    assert.ok(layout.singleRow && layout.scrollWidth <= layout.width && layout.scrollHeight <= layout.height &&
      (windowWidth ?? layout.width) <= 400, 'The compact bar must fit one row independently of the main popup: ' + JSON.stringify(layout));
  }
  await assertBarLayout();
  assert.equal(await run('mini.document.documentElement.dataset.theme'), 'dark');
  await assertIcon('[data-action=run]', 'Pause', 'pause', 'mini.document');
  await assertIcon('[data-action=next]', 'Finish', 'stop', 'mini.document');
  await assertIcon('[data-action=undo]', 'Undo', 'undo', 'mini.document');
  assert.equal(await run("mini.document.querySelector('[data-action=back]')"), null);
  const initialClock = await run('miniUI.clock.textContent');
  await until(async () => await run('miniUI.clock.textContent') !== initialClock);
  await barClick('next');
  assert.ok(await run("miniUI.message.textContent.includes('Meeting ended')"));
  await assertBarLayout();
  await assertIcon('[data-action=run]', 'Start', 'play', 'mini.document');
  await assertIcon('[data-action=next]', 'Next', 'skip', 'mini.document');
  await barClick('undo');
  await barClick('run');
  assert.equal(await run("miniUI.count.textContent + ' ' + miniUI.message.textContent"), '2 / 2 Paused');
  await assertBarLayout();
  assert.ok(await run("miniUI.next.disabled"));
  await barClick('run');
  await barClick('next');
  await barClick('run');
  await barClick('next');
  assert.equal(await run('miniUI.count.textContent'), '2 / 2');
  await barClick('run');
  await assertBarLayout();
  const barFontSize = () => run('parseFloat(mini.getComputedStyle(miniUI.clock).fontSize)');
  const initialBarFontSize = await barFontSize();
  await run('mini.resizeBy(320, 150)');
  await until(() => run("!mini.document.querySelector('[data-action=reset]').hidden"));
  assert.ok(await barFontSize() > Math.max(68, initialBarFontSize), 'The enlarged presenter clock grows beyond its former size limit');
  await assertIcon('[data-action=reset]', 'Restore default size', 'reset-size', 'mini.document');
  await barClick('reset');
  await until(defaultBarSize);
  assert.ok(await run("miniUI.count.textContent === '2 / 2' && miniUI.message.textContent === 'Paused'"));
  await leaveBar();
  await restored();
  assert.equal(await run("el('status').textContent"), 'Paused');
  await open();
  await run('mini.resizeBy(110, 80)');
  await until(async () => (await barSize())[0] > initialBarSize[0]);
  await leaveBar();
  await restored();
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {left: 20, top: 20, width: 660, height: 460})');
  await open();
  await until(defaultBarSize);
  await assertBarLayout();
  await evaluate(worker, 'openTimer()');
  await restored();
  await run(`history.replaceState(null, '', '#timer-resize');
    chrome.runtime.sendMessage = () => { throw new Error('Size reset must not contact the service worker'); };`);
  await click('#resetSize');
  await until(async () => matchesSize(await popupSize(), initialPopupSize));
  assert.equal(await run("el('status').textContent"), 'Paused');
  assert.ok(await run("!el('notice').textContent.includes('Could not restore the window size')"));
  await run("void Object.defineProperty(window, 'documentPictureInPicture', {configurable: true, value: undefined})");
  await pressBarShortcut();
  await until(async () => await popupState() === 'minimized' && await run('!!miniUI'));
  const fallbackSize = () => evaluate(worker, `chrome.windows.getAll().then(windows => {
    const bar = windows.find(window => window.type === 'popup' && window.id !== ${popupId});
    return [bar.width, bar.height];
  })`);
  const fallbackBarSize = await fallbackSize();
  await assertBarLayout();
  await run('mini.resizeBy(132, 84)');
  await until(() => run("!mini.document.querySelector('[data-action=reset]').hidden")).catch(async error => {
    const windows = await evaluate(worker, 'chrome.windows.getAll()');
    throw new Error('Fallback size ' + JSON.stringify(fallbackBarSize) + ' → ' + JSON.stringify(await barSize()) +
      ', windows ' + JSON.stringify(windows.map(w => [w.id, w.type, w.state, w.width, w.height])), {cause: error});
  });
  await barClick('reset');
  await until(async () => matchesSize(await fallbackSize(), fallbackBarSize) &&
    await run("mini.document.querySelector('[data-action=reset]').hidden"));
  // Verify native popup size even when the minimized opener reports its old viewport.
  await assertBarLayout((await fallbackSize())[0]);
  await leaveBar();
  await restored();
  await run('delete window.documentPictureInPicture');
  const resizeUrl = await run("chrome.runtime.getURL('index.html?resize-test=1')");
  await call('Page.navigate', {url: resizeUrl}, page);
  await until(() => run("location.search === '?resize-test=1' && document.readyState === 'complete' && !el('resetSize').hidden"));
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "maximized"})');
  await until(async () => await popupState() === 'maximized' && (await popupSize())[0] > initialPopupSize[0]);
  await click('#resetSize');
  await until(async () => await popupState() === 'normal' && matchesSize(await popupSize(), initialPopupSize));
  await until(() => run("!el('resetSize').disabled"));
  assert.equal(await run("el('status').textContent"), 'Paused');
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {left: 20, top: 20, width: 616, height: 450})');
  await until(async () => await popupState() === 'normal' &&
    matchesSize(await popupSize(), [616, 450]) &&
    matchesSize(await run('[outerWidth, outerHeight]'), [616, 450]));
  await run(`const nativeWindowUpdate = chrome.windows.update;
    let rejectedWindowUpdates = 0;
    chrome.windows.update = () => {
      rejectedWindowUpdates++;
      return Promise.reject(new Error('Simulated Chrome window API failure'));
    };`);
  // Exercise the failure branch with a user gesture independent of OS input coordinates.
  await run("el('resetSize').click()");
  await until(() => run("rejectedWindowUpdates === 1 && !el('resetSize').disabled"));
  await until(async () => matchesSize(await popupSize(), initialPopupSize));
  assert.ok(await run("!el('notice').textContent.includes('Could not restore the window size')"));
  await run('chrome.windows.update = nativeWindowUpdate');
  await click('#edit');
  await run("el('countInput').value = 3");
  await clickConfirm('button[type=submit]', false);
  assert.ok(await run("settings.open && el('speaker').textContent === 'Speaker 2'"));
  await clickConfirm('button[type=submit]', true);
  await until(() => run("!settings.open && el('status').textContent === 'Ready' && el('segments').children.length === 3"));
  assert.equal(dialogAnswers.length, 0, 'Both confirmation choices were exercised');

  // Seed meetings at exact offsets, then exercise transitions through the actual controls.
  await run(`const realScenarioNow = Date.now;
    const savedScenarioState = state, savedScenarioPrevious = previous;
    let scenarioNow = Date.now();
    Date.now = () => scenarioNow;
    function seedScenario(secondsLeft) {
      state = meeting(2, scenarioNow + secondsLeft * 1000);
      previous = null;
      render();
    }`);
  try {
    await run('seedScenario(90)');
    assert.equal(await run("el('clock').textContent"), '01:00');
    await clickButton('#run');
    assert.deepEqual(await run("[state.plan, state.budget, el('delta').hidden]"), [60_000, 60_000, true]);

    await run('seedScenario(600)');
    await clickButton('#run');
    assert.equal(await run("el('clock').textContent"), '05:00');
    await run('scenarioNow += 60_000');
    await clickButton('#next');
    assert.deepEqual(await run("[el('speaker').textContent, el('clock').textContent, el('deltaValue').textContent]"),
      ['Speaker 2', '09:00', '+04:00']);
    await run('scenarioNow += 12_000');
    await clickButton('#undo');
    await until(() => run("el('speaker').textContent === 'Speaker 1' && el('undo').disabled"));
    assert.deepEqual(await run("[el('speaker').textContent, el('clock').textContent, el('delta').hidden, el('undo').disabled, el('run').textContent]"),
      ['Speaker 1', '03:48', true, true, 'Pause']);

    await run('scenarioNow += 541_000; render()');
    await clickConfirm('#next', false);
    assert.deepEqual(await run("[el('speaker').textContent, el('clock').textContent, el('undo').disabled]"),
      ['Speaker 1', '+05:13', true]);
    await clickConfirm('#next', true);
    await until(() => run("el('speaker').textContent === 'Speaker 2'"));
    assert.deepEqual(await run("[el('speaker').textContent, state.budget, el('run').textContent]"),
      ['Speaker 2', 0, 'Pause']);
    await run('scenarioNow += 10_000; render()');
    assert.equal(await run("el('clock').textContent"), '+00:10');
    await clickButton('#undo');
    await until(() => run("el('speaker').textContent === 'Speaker 1' && el('undo').disabled"));
    assert.deepEqual(await run("[el('speaker').textContent, el('clock').textContent, state.plan, el('undo').disabled]"),
      ['Speaker 1', '+05:23', 300_000, true]);
  } finally {
    await run("Date.now = realScenarioNow; state = savedScenarioState; previous = savedScenarioPrevious; notify(''); save()");
  }

  // Keep device emulation after the native popup input and PiP checks.
  let priorSize = 0;
  for (const [width, height] of [[600, 400], [1200, 800], [1000, 185], [280, 700]]) {
    await call('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 1, mobile: false}, page);
    await until(() => run('innerWidth === ' + width + ' && innerHeight === ' + height));
    const size = await run("parseFloat(getComputedStyle(el('clock')).fontSize)");
    if (width === 1200) assert.ok(size > 1.9 * priorSize, 'The main clock scales with the available space');
    priorSize = size;
    await assertStageFits();
  }
  await run('state = {...state, budget: 0, elapsed: 10000 * minute, started: null}; render()');
  assert.equal(await run("el('clock').textContent"), '+10000:00');
  await assertStageFits();
  await run('state = savedScenarioState; render()');
  await run("state = {...state, index: 1, plan: 10 * minute, budget: 12 * minute}; render()");
  await call('Emulation.setDeviceMetricsOverride', {width: 280, height: 196, deviceScaleFactor: 1, mobile: false}, page);
  await until(() => run("innerWidth === 280"));
  assert.ok(await run(`(() => {
    const delta = el('delta').getBoundingClientRect();
    const left = el('left').getBoundingClientRect();
    return !el('delta').hidden && document.documentElement.scrollWidth === innerWidth &&
      delta.right <= left.left && delta.y > el('deadline').getBoundingClientRect().y;
  })()`), 'The narrow timer must fit the visible plan comparison and time remaining');
  await assertActionRow();
  await assertStageFits();
  await run("notify('Meeting ended. Use Undo to return to the last speaker.')");
  await assertStageFits();
  await call('Emulation.setDeviceMetricsOverride', {width: 280, height: 154, deviceScaleFactor: 1, mobile: false}, page);
  await until(() => run("innerHeight === 154"));
  await run("el('edit').click()");
  await assertSettingsControls();
  const regularTab = await evaluate(worker, `chrome.windows.getAll().then(windows => chrome.tabs.create({
    windowId: windows.find(popup => popup.type === 'normal').id,
    url: chrome.runtime.getURL('index.html#regular-test'), active: false
  }))`);
  const regularPage = await attach('/index.html#regular-test');
  await until(() => evaluate(regularPage, "document.readyState === 'complete' && !!el('resetSize').onclick"));
  const regularSize = await evaluate(regularPage, '[outerWidth, outerHeight]');
  assert.ok(await evaluate(regularPage, "el('resetSize').hidden"));
  await evaluate(regularPage, "el('resetSize').click()");
  assert.deepEqual(await evaluate(regularPage, '[outerWidth, outerHeight]'), regularSize);
  await evaluate(worker, 'chrome.tabs.remove(' + regularTab.id + ')');
  await run('settings.close()');
  await call('Emulation.clearDeviceMetricsOverride', {}, page);
  await until(() => run('innerHeight > 154'));
  await run('let testNow = new Date(2026, 0, 5, 14).getTime(); Date.now = () => testNow; state = meeting(2, testNow + 60 * minute); save()');
  await click('#edit');
  assert.equal(await run("el('wrapInput').value"), '0');
  await run("el('wrapInput').value = 5");
  await click('button[type=submit]');
  assert.equal(await run('allocation(state, testNow)'), 1_650_000);
  await click('#run');
  await run('testNow += 25 * minute; render()');
  await click('#next');
  assert.equal(await run('state.budget'), 1_800_000);
  assert.equal(await run("el('next').textContent"), 'Start wrap-up');
  await run('testNow += 29 * minute');
  await click('#next');
  assert.deepEqual(await run("[el('speaker').textContent, el('clock').textContent, el('run').hidden]"), ['Wrap-up', '06:00', true]);
  await click('#undo');
  assert.equal(await run("el('speaker').textContent"), 'Speaker 2');
  await run('testNow += 7 * minute');
  await click('#next');
  assert.equal(await run("el('clock').textContent"), '+01:00');
  await click('#next');
  assert.equal(await run('state.wrapMinutes'), 5);
  await click('#undo');
  assert.equal(await run("el('clock').textContent"), '+01:00');
  await click('#undo');
  assert.equal(await run("el('speaker').textContent"), 'Speaker 2');

  await run('testNow = new Date(2026, 0, 5, 14, 54).getTime(); state = meeting(2, testNow + 6 * minute, 5); save()');
  await open();
  await barClick('run');
  const choice = () => run("mini.document.querySelector('.speakerChoice')?.textContent");
  async function choose(value) {
    const reachable = await run(`(() => {
      const doc = mini.document;
      const button = doc.querySelector('.speakerChoice [value=${value}]');
      const box = button.getBoundingClientRect();
      if (!button.contains(doc.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2))) return false;
      button.click();
      return true;
    })()`);
    assert.ok(reachable, 'The compact presenter bar must expose the ' + value + ' choice');
  }
  assert.match(await choice(), /Keep: 00:30 each · 05:00 wrap-up/);
  assert.match(await choice(), /Use: 01:00 each · 04:00 wrap-up/);
  await run('advance(); toggle(); undo()');
  assert.equal(await run('state.started'), null, 'An open presenter choice prevents stale changes from other actions');
  await choose('cancel');
  await until(() => run('speakerChoice === null'));
  assert.equal(await run('state.started'), null);
  await barClick('run');
  await run('testNow += 6 * minute');
  await choose('use');
  await until(async () => (await choice())?.includes('Track the next speaker in overtime?'));
  await choose('cancel');
  await until(() => run('speakerChoice === null'));
  assert.equal(await run('state.started'), null);
  await run('testNow -= 6 * minute');
  await barClick('run');
  await choose('keep');
  await until(() => run('state.budget === 30000'));
  await run('testNow += 30 * 1000; render()');
  await barClick('next');
  await choose('use');
  await until(() => run('state.budget === minute'));
  assert.equal(await run('state.reserve'), 270_000);
  await assertIcon('[data-action=next]', 'Start wrap-up', 'wrap', 'mini.document');
  await run('testNow += 2 * minute; render()');
  await barClick('next');
  assert.deepEqual(await run('[miniUI.count.textContent, miniUI.clock.textContent, miniUI.run.hidden]'), ['Wrap-up', '03:30', true]);
  await assertIcon('[data-action=next]', 'Finish', 'stop', 'mini.document');
  await barClick('next');
  await barClick('undo');
  assert.equal(await run('miniUI.count.textContent'), 'Wrap-up');
  await barClick('undo');
  assert.equal(await run('miniUI.count.textContent'), '2 / 2');
  await leaveBar();
  await restored();
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "minimized"})', false);
  await until(barReady);
  const finalBar = await presenterPopup();
  await closeBarWindow(finalBar.id);
  const windowGone = id => evaluate(worker, 'chrome.windows.getAll().then(ws => ws.every(w => w.id !== ' + id + '))');
  await until(() => windowGone(popupId));
  assert.ok(await windowGone(finalBar.id), 'Close exits both the bar and the timer');

  await evaluate(worker, 'openTimer()');
  const freshTimer = await attach('/index.html');
  await until(() => evaluate(freshTimer, 'document.readyState === "complete" && typeof openBar === "function"'));
  const freshId = await evaluate(freshTimer, 'chrome.windows.getCurrent().then(w => w.id)');
  await evaluate(freshTimer, 'openBar()');
  await evaluate(freshTimer, 'documentPictureInPicture.window.close()');
  await until(() => windowGone(freshId));
  assert.ok(await evaluate(worker, 'chrome.windows.getAll().then(ws => ws.some(w => w.type === "normal"))'));
  await call('Browser.close', {});
});
