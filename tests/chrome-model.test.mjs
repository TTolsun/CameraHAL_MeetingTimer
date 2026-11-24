import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {runInNewContext} from 'node:vm';

const extension = process.env.TIMER_EXTENSION_DIR || fileURLToPath(new URL('../chrome-extension', import.meta.url));
const modelPath = join(extension, 'time-model.js');
const model = readFileSync(modelPath, 'utf8');
const {allocation, meeting, startSpeaker} = runInNewContext(
  model + '\n;({allocation, meeting, startSpeaker});', {}, {filename: modelPath});

test('the Chrome first plan includes the minimum allocation', () => {
  const now = Date.UTC(2026, 0, 5, 14, 0);
  const state = meeting(2, now + 90_000);
  assert.equal(state.plan, null);
  assert.equal(allocation(state, now), 60_000);
  startSpeaker(state, now);
  assert.equal(state.plan, 60_000);
  assert.equal(state.budget, 60_000);
  assert.equal(state.started, now);
});

test('starting a later speaker keeps the first plan for comparison', () => {
  const now = Date.UTC(2026, 0, 5, 14, 0);
  const state = meeting(2, now + 600_000);
  startSpeaker(state, now);
  assert.equal(state.budget, 300_000);
  state.index++;
  state.budget = null;
  startSpeaker(state, now + 60_000);
  assert.equal(state.budget, 540_000);
  assert.equal(state.plan, 300_000);
});

test('starting an approved overtime turn records a locked zero allocation', () => {
  const deadline = Date.UTC(2026, 0, 5, 15, 0);
  const state = meeting(2, deadline);
  startSpeaker(state, deadline + 1_000);
  assert.equal(state.plan, 0);
  assert.equal(state.budget, 0);
  assert.equal(state.started, deadline + 1_000);
  state.started = null;
  startSpeaker(state, deadline - 1_000);
  assert.equal(state.budget, 0, 'Resume keeps the locked budget even if the system clock changed');
  assert.equal(state.plan, 0);
});
