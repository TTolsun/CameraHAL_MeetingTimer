'use strict';

const minute = 60000;
function nextHour(now) {
  const date = new Date(now);
  date.setMinutes(0, 0, 0);
  date.setHours(date.getHours() + 1);
  if (date.getTime() - now < 10 * minute) date.setHours(date.getHours() + 1);
  return date.getTime();
}
function meeting(count, end) {
  return {count, end, index: 0, plan: null, budget: null, elapsed: 0, started: null};
}
function valid(s) {
  return s && Number.isInteger(s.count) && s.count >= 1 && s.count <= 50 &&
    Number.isInteger(s.index) && s.index >= 0 && s.index < s.count && Number.isFinite(s.end) &&
    Number.isFinite(s.elapsed) && s.elapsed >= 0 &&
    (s.budget === null || Number.isFinite(s.budget) && s.budget >= 0) &&
    (s.started === null || Number.isFinite(s.started) && s.budget !== null);
}
function allocation(state, now) {
  const left = state.end - now;
  if (left <= 0) return 0;
  return Math.max(minute, Math.floor(left / (state.count - state.index) / 1000) * 1000);
}
function remaining(state, now) {
  const used = state.elapsed + (state.started === null ? 0 : Math.max(0, now - state.started));
  return (state.budget ?? allocation(state, now)) - used;
}
function duration(ms) {
  const seconds = ms < 0 ? Math.floor(-ms / 1000) : Math.ceil(ms / 1000);
  return (ms < 0 ? '+' : '') + String(Math.floor(seconds / 60)).padStart(2, '0') + ':' +
    String(seconds % 60).padStart(2, '0');
}
function hour(ms) {
  const date = new Date(ms);
  return [date.getHours(), date.getMinutes()].map(n => String(n).padStart(2, '0')).join(':');
}
