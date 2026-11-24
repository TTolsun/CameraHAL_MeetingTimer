import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {runInNewContext} from 'node:vm';

const extension = process.env.TIMER_EXTENSION_DIR || fileURLToPath(new URL('../chrome-extension', import.meta.url));
const modelPath = join(extension, 'time-model.js');
const model = readFileSync(modelPath, 'utf8');
const {allocation, meeting, remaining, restoreMeeting, startSpeaker, valid, wrapOptions} = runInNewContext(
  model + '\n;({allocation, meeting, remaining, restoreMeeting, startSpeaker, valid, wrapOptions});', {}, {filename: modelPath});

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

test('wrap-up estimates reflect the minutes actually available', () => {
  const deadline = Date.UTC(2026, 0, 5, 15);
  const state = meeting(2, deadline, 5);
  const at1454 = wrapOptions(state, deadline - 360_000, 0);
  assert.deepEqual({...at1454}, {keepReserve: 300_000, keepShare: 30_000, useShare: 60_000, reserve: 240_000});
  const at1457 = wrapOptions(state, deadline - 180_000, 0);
  assert.deepEqual({...at1457}, {keepReserve: 180_000, keepShare: 0, useShare: 60_000, reserve: 60_000});
  assert.equal(wrapOptions(state, deadline, 0), null);
});

test('legacy sessions keep zero wrap-up and stored wrap-up counts against the real end', () => {
  const deadline = Date.UTC(2026, 0, 5, 15);
  const {wrapMinutes, reserve, wrapStart, ...legacy} = meeting(1, deadline);
  assert.ok(valid(legacy));
  assert.equal(restoreMeeting(legacy).wrapMinutes, 0);
  const wrapped = {...meeting(1, deadline, 5), budget: 60_000, wrapStart: deadline - 120_000};
  assert.ok(valid(wrapped));
  assert.equal(remaining(restoreMeeting(wrapped), deadline - 90_000), 90_000);
  assert.equal(remaining(restoreMeeting(wrapped), deadline + 30_000), -30_000);
});
