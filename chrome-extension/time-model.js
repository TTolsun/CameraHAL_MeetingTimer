'use strict';

const minute = 60000;
function nextHour(now) {
  const date = new Date(now);
  date.setMinutes(0, 0, 0);
  date.setHours(date.getHours() + 1);
  if (date.getTime() - now < 10 * minute) date.setHours(date.getHours() + 1);
  return date.getTime();
}
function meeting(count, end, wrapMinutes = 0) {
  return {count, end, index: 0, plan: null, budget: null, elapsed: 0, started: null,
    wrapMinutes, reserve: wrapMinutes * minute, wrapStart: null};
}
function validWrapMinutes(value) {
  return Number.isInteger(value) && value >= 0 && value <= 59;
}
function valid(s) {
  return s && Number.isInteger(s.count) && s.count >= 1 && s.count <= 50 &&
    Number.isInteger(s.index) && s.index >= 0 && s.index < s.count && Number.isFinite(s.end) &&
    Number.isFinite(s.elapsed) && s.elapsed >= 0 &&
    (s.budget === null || Number.isFinite(s.budget) && s.budget >= 0) &&
    (s.started === null || Number.isFinite(s.started) && s.budget !== null) &&
    (s.wrapMinutes === undefined && s.reserve === undefined && s.wrapStart === undefined ||
      validWrapMinutes(s.wrapMinutes) &&
      Number.isFinite(s.reserve) && s.reserve >= 0 && s.reserve <= s.wrapMinutes * minute &&
      (s.wrapStart === null || Number.isFinite(s.wrapStart) && s.wrapMinutes > 0 &&
        s.index === s.count - 1 && s.started === null && s.budget !== null));
}
function restoreMeeting(saved) {
  return {...meeting(saved.count, saved.end), ...saved};
}
function speakerShare(left, count) {
  return Math.max(0, Math.floor(left / count / 1000) * 1000);
}
function allocation(state, now) {
  const left = state.end - now - state.reserve;
  const share = speakerShare(left, state.count - state.index);
  return state.wrapMinutes || left <= 0 ? share : Math.max(minute, share);
}
function wrapOptions(state, now, index) {
  const left = Math.max(0, state.end - now);
  const count = state.count - index;
  const release = Math.min(state.reserve, Math.max(0, count * minute - (left - state.reserve)));
  if (left === 0 || release === 0) return null;
  const reducedReserve = state.reserve - release;
  return {
    keepReserve: Math.min(left, state.reserve),
    keepShare: speakerShare(left - state.reserve, count),
    useShare: speakerShare(left - reducedReserve, count),
    reserve: reducedReserve
  };
}
function remaining(state, now) {
  if (state.wrapStart !== null) return state.end - now;
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

function startSpeaker(state, now) {
  state.budget ??= allocation(state, now);
  state.plan ??= state.budget;
  state.started = now;
}
