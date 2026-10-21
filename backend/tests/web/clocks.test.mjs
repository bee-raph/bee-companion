import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {test} from 'node:test';
const source = await readFile(new URL('../../app/web/clocks.js', import.meta.url), 'utf8');
const {formatClock, refreshClocks} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const cases = [
  ['Asia/Jerusalem', '2026-03-26T23:59Z', '01:59', 'GMT+2'],
  ['Asia/Jerusalem', '2026-03-27T00:00Z', '03:00', 'GMT+3'],
  ['Asia/Jerusalem', '2026-10-24T22:59Z', '01:59', 'GMT+3'],
  ['Asia/Jerusalem', '2026-10-24T23:00Z', '01:00', 'GMT+2'],
  ['Europe/London', '2026-03-29T00:59Z', '00:59', 'GMT'],
  ['Europe/London', '2026-03-29T01:00Z', '02:00', 'GMT+1'],
  ['Europe/London', '2026-10-25T00:59Z', '01:59', 'GMT+1'],
  ['Europe/London', '2026-10-25T01:00Z', '01:00', 'GMT'],
  ['America/New_York', '2026-03-08T06:59Z', '01:59', 'GMT-5'],
  ['America/New_York', '2026-03-08T07:00Z', '03:00', 'GMT-4'],
  ['America/New_York', '2026-11-01T05:59Z', '01:59', 'GMT-4'],
  ['America/New_York', '2026-11-01T06:00Z', '01:00', 'GMT-5'],
];
for (const [zone, instant, time, offset] of cases) {
  test(`${zone}: ${instant} uses ${offset}`, () => {
    const actual = formatClock(new Date(instant), zone, 'en-GB');
    assert.equal(actual.time, time);
    assert.equal(actual.offset, offset);
  });
}
test('each clock independently applies its own DST transition date', () => {
  const instant = new Date('2026-03-15T12:00Z');
  assert.equal(formatClock(instant, 'America/New_York', 'en-GB').offset, 'GMT-4');
  assert.equal(formatClock(instant, 'Europe/London', 'en-GB').offset, 'GMT');
  assert.equal(formatClock(instant, 'Asia/Jerusalem', 'en-GB').offset, 'GMT+2');
});
test('non-DST zones and southern hemisphere DST work without fixed offsets', () => {
  assert.equal(formatClock(new Date('2026-01-15T12:00Z'), 'Asia/Kolkata', 'en-GB').offset, 'GMT+5:30');
  assert.equal(formatClock(new Date('2026-07-15T12:00Z'), 'Asia/Kolkata', 'en-GB').offset, 'GMT+5:30');
  assert.equal(formatClock(new Date('2026-01-15T12:00Z'), 'Australia/Sydney', 'en-GB').offset, 'GMT+11');
  assert.equal(formatClock(new Date('2026-07-15T12:00Z'), 'Australia/Sydney', 'en-GB').offset, 'GMT+10');
});
test('display refresh advances existing clocks without a sync or rerender', () => {
  const time = {}, date = {};
  const root = {querySelectorAll: () => [{dataset: {clockZone: 'Europe/London'}, querySelector: selector => selector === '[data-clock-time]' ? time : date}]};
  refreshClocks(root, new Date('2026-03-29T00:59Z'));
  const before = time.textContent;
  refreshClocks(root, new Date('2026-03-29T01:00Z'));
  assert.notEqual(time.textContent, before);
  assert.ok(date.textContent.includes('GMT+1'));
});
test('the date belongs to each displayed zone, including across midnight', () => {
  const instant = new Date('2026-07-01T00:30Z');
  assert.ok(formatClock(instant, 'America/New_York', 'en-GB').date.includes('30 Jun'));
  assert.ok(formatClock(instant, 'Asia/Jerusalem', 'en-GB').date.includes('1 Jul'));
});
