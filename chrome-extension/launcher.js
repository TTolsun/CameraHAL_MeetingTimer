'use strict';

importScripts('window-size.js');

async function openTimer() {
  const url = chrome.runtime.getURL('index.html');
  // Chrome can suspend the worker while the timer window stays open.
  const [timer] = await chrome.runtime.getContexts({
    contextTypes: ['TAB'],
    documentUrls: [url]
  });
  if (timer) {
    try {
      await chrome.runtime.sendMessage({action: 'return-to-timer', windowId: timer.windowId}).catch(() => {});
      await chrome.tabs.update(timer.tabId, {active: true});
      const existing = await chrome.windows.get(timer.windowId);
      if (existing.state === 'minimized') await chrome.windows.update(timer.windowId, {state: 'normal'});
      await chrome.windows.update(timer.windowId, {focused: true});
      return;
    } catch {
      // The timer window may have been closed between discovery and focus.
    }
  }
  await chrome.windows.create({url, type: 'popup', ...timerBounds, focused: true});
}

let opening;
chrome.action.onClicked.addListener(() => {
  if (!opening) {
    opening = openTimer().catch(error => console.error('Timer window:', error)).finally(() => {
      opening = null;
    });
  }
});
