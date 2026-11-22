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
  socket.onmessage = ({data}) => {
    const message = JSON.parse(data);
    if (message.method === 'Page.javascriptDialogOpening') {
      const accept = dialogAnswers.shift() ?? false;
      void call('Page.handleJavaScriptDialog', {accept}, message.sessionId);
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
  async function evaluate(session, expression) {
    const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true, userGesture: true}, session);
    assert.ok(!result.exceptionDetails, result.exceptionDetails?.exception?.description || expression);
    return result.result.value;
  }
  const worker = await attach('/launcher.js');
  await until(() => evaluate(worker, "typeof openTimer === 'function'"));
  await evaluate(worker, 'openTimer()');
  const page = await attach('/index.html');
  await call('Page.enable', {}, page);
  const run = expression => evaluate(page, expression);
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
  assert.ok(await run("el('mini').textContent.trim() === '발표 막대 열기' && !!el('mini').querySelector('svg[data-icon=bar]')"));
  await assertIcon('#edit', '회의 설정', 'settings');
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
  await assertIcon('#theme', '어두운 화면으로 전환', 'moon');
  await click('#theme');
  assert.equal(await run("localStorage.getItem('timer-theme')"), 'dark');
  await call('Page.reload', {}, page);
  await until(() => run("document.readyState === 'complete' && document.documentElement.dataset.theme === 'dark'"));
  await click('#edit');
  await assertIcon('#theme', '밝은 화면으로 전환', 'sun');
  await click('#theme');
  assert.equal(await run("document.documentElement.dataset.theme"), 'light');
  await run("el('countInput').value = 49");
  await click('#cancel');
  await click('#edit');
  assert.equal(await run("el('countInput').value"), '6');
  await run("el('countInput').value = 50; el('endInput').value = hour(Date.now() + 5 * minute)");
  await click('button[type=submit]');
  assert.ok(await run("settings.open && el('settingHint').textContent.includes('최소 1분')"));
  await run("el('endInput').value = hour(Date.now() - minute); el('endInput').dispatchEvent(new Event('input', {bubbles:true}))");
  if (await run("new Date().getHours() + new Date().getMinutes() > 0")) {
    assert.ok(await run("el('endLabel').textContent.includes('다음 날')"));
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
  assert.match(await run("el('delta').hidden ? '' : el('delta').textContent"), /^계획 대비 \+\d+:\d{2}$/);
  assert.equal(await run("el('deadline').getBoundingClientRect().x"), deadlineX);
  assert.equal(await run("el('next').textContent"), '종료');
  await call('Input.dispatchKeyEvent', {type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32}, page);
  await call('Input.dispatchKeyEvent', {type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32}, page);
  assert.ok(await run("el('speaker').textContent === '발표자 2' && el('run').textContent === '계속'"));
  await click('#run');
  await click('#next');
  assert.ok(await run("el('notice').textContent.includes('회의 종료') && el('next').hidden"));
  await assertStageFits();
  assert.ok(await run("el('delta').hidden"));
  await click('#undo');
  assert.equal(await run("el('speaker').textContent"), '발표자 2');
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
  await assertIcon('#resetSize', '기본 크기로 복원', 'reset-size');
  const open = async () => {
    await click('#mini');
    await until(async () => await popupState() === 'minimized');
    assert.ok(await run("!!documentPictureInPicture.window?.document.querySelector('.miniClock')"));
  };
  const restored = async () => {
    await until(async () => await popupState() === 'normal' && await run("!mini && !el('mini').disabled"));
  };
  await open();
  const barSize = () => run('[mini.outerWidth, mini.outerHeight]');
  const initialBarSize = await barSize();
  const matchesSize = (actual, expected) => actual.every((value, axis) => Math.abs(value - expected[axis]) <= 2);
  const defaultBarSize = async () => matchesSize(await barSize(), initialBarSize);
  assert.ok(await run("mini.document.querySelector('[data-action=reset]').hidden"));
  async function assertBarLayout() {
    await until(() => run("mini.getComputedStyle(mini.document.querySelector('.miniBar')).display === 'grid'"));
    const layout = await run(`(() => {
      const doc = mini.document;
      const bar = doc.querySelector('.miniBar');
      const boxes = Array.from(bar.children).slice(0, 3).map(child => child.getBoundingClientRect());
      return {width: mini.innerWidth, height: mini.innerHeight, scrollWidth: doc.documentElement.scrollWidth,
        scrollHeight: doc.documentElement.scrollHeight,
        singleRow: boxes.every(box => Math.abs((box.top + box.bottom) / 2 - (boxes[0].top + boxes[0].bottom) / 2) < 1)};
    })()`);
    assert.ok(layout.singleRow && layout.scrollWidth <= layout.width && layout.scrollHeight <= layout.height &&
      layout.width <= 400, 'The compact bar must fit one row independently of the main popup: ' + JSON.stringify(layout));
  }
  await assertBarLayout();
  assert.equal(await run('mini.document.documentElement.dataset.theme'), 'dark');
  await assertIcon('[data-action=run]', '일시정지', 'pause', 'mini.document');
  await assertIcon('[data-action=next]', '종료', 'stop', 'mini.document');
  await assertIcon('[data-action=undo]', '되돌리기', 'undo', 'mini.document');
  await assertIcon('[data-action=back]', '기본 창으로 돌아가기', 'back', 'mini.document');
  const initialClock = await run('miniUI.clock.textContent');
  await until(async () => await run('miniUI.clock.textContent') !== initialClock);
  await barClick('next');
  assert.ok(await run("miniUI.message.textContent.includes('회의 종료')"));
  await assertBarLayout();
  await assertIcon('[data-action=run]', '시작', 'play', 'mini.document');
  await assertIcon('[data-action=next]', '다음', 'skip', 'mini.document');
  await barClick('undo');
  await barClick('run');
  assert.equal(await run("miniUI.count.textContent + ' ' + miniUI.message.textContent"), '2 / 2명 일시정지');
  await assertBarLayout();
  assert.ok(await run("miniUI.next.disabled"));
  await barClick('run');
  await barClick('next');
  await barClick('run');
  await barClick('next');
  assert.equal(await run('miniUI.count.textContent'), '2 / 2명');
  await barClick('run');
  await assertBarLayout();
  const barFontSize = () => run('parseFloat(mini.getComputedStyle(miniUI.clock).fontSize)');
  const initialBarFontSize = await barFontSize();
  await run('mini.resizeBy(110, 80)');
  await until(() => run("!mini.document.querySelector('[data-action=reset]').hidden"));
  assert.ok(await barFontSize() > initialBarFontSize, 'The clock must use the available space when the bar is enlarged');
  await assertIcon('[data-action=reset]', '기본 크기로 복원', 'reset-size', 'mini.document');
  await barClick('reset');
  await until(defaultBarSize);
  assert.ok(await run("miniUI.count.textContent === '2 / 2명' && miniUI.message.textContent === '일시정지'"));
  await barClick('back');
  await restored();
  assert.equal(await run("el('status').textContent"), '일시정지');
  await open();
  await run('mini.resizeBy(110, 80)');
  await until(async () => (await barSize())[0] > initialBarSize[0]);
  await run('documentPictureInPicture.window.close()');
  await restored();
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {width: 660, height: 460})');
  await open();
  await until(defaultBarSize);
  await assertBarLayout();
  await evaluate(worker, 'openTimer()');
  await restored();
  await run(`history.replaceState(null, '', '#timer-resize');
    chrome.runtime.sendMessage = () => { throw new Error('Size reset must not contact the service worker'); };`);
  await click('#resetSize');
  await until(async () => String(await popupSize()) === String(initialPopupSize));
  assert.equal(await run("el('status').textContent"), '일시정지');
  assert.ok(await run("!el('notice').textContent.includes('창 크기를 복원할 수 없습니다')"));
  await run("void Object.defineProperty(window, 'documentPictureInPicture', {configurable: true, value: undefined})");
  await click('#mini');
  await until(async () => await popupState() === 'minimized' && await run('!!miniUI'));
  const fallbackBarSize = await barSize();
  await assertBarLayout();
  await evaluate(worker, `chrome.windows.getAll().then(windows => {
    const fallback = windows.find(window => window.type === 'popup' && window.id !== ${popupId});
    return chrome.windows.update(fallback.id, {width: 460, height: 220});
  })`);
  await until(() => run("!mini.document.querySelector('[data-action=reset]').hidden"));
  await barClick('reset');
  await until(async () => matchesSize(await barSize(), fallbackBarSize));
  await assertBarLayout();
  await barClick('back');
  await restored();
  await run('delete window.documentPictureInPicture');
  const resizeUrl = await run("chrome.runtime.getURL('index.html?resize-test=1')");
  await call('Page.navigate', {url: resizeUrl}, page);
  await until(() => run("location.search === '?resize-test=1' && document.readyState === 'complete' && !el('resetSize').hidden"));
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {state: "maximized"})');
  await until(async () => await popupState() === 'maximized' && await run('outerWidth > ' + initialPopupSize[0]));
  await click('#resetSize');
  await until(async () => await popupState() === 'normal' && String(await popupSize()) === String(initialPopupSize));
  await until(() => run("!el('resetSize').disabled"));
  assert.equal(await run("el('status').textContent"), '일시정지');
  await evaluate(worker, 'chrome.windows.update(' + popupId + ', {width: 616, height: 450})');
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
  assert.ok(await run("!el('notice').textContent.includes('창 크기를 복원할 수 없습니다')"));
  await run('chrome.windows.update = nativeWindowUpdate');
  await click('#edit');
  await run("el('countInput').value = 3");
  dialogAnswers.push(false);
  await click('button[type=submit]');
  assert.ok(await run("settings.open && el('speaker').textContent === '발표자 2'"));
  dialogAnswers.push(true);
  await click('button[type=submit]');
  assert.ok(await run("!settings.open && el('status').textContent === '대기' && el('segments').children.length === 3"));
  assert.equal(dialogAnswers.length, 0, 'Both confirmation choices were exercised');
  // Keep device emulation after the native popup input and PiP checks.
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
  await run("notify('회의 종료 · 되돌리기로 마지막 발표를 복원할 수 있습니다.')");
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
  await call('Browser.close', {});
});
