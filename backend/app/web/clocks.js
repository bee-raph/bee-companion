// Format the same absolute instant independently in each IANA zone.
// Intl uses the browser's time-zone database, including that zone's DST rules.
export function formatClock(instant, timeZone, locale) {
  const zone = timeZone.trim();
  return {
    time: new Intl.DateTimeFormat(locale, {
      timeZone: zone, hour: '2-digit', minute: '2-digit',
    }).format(instant),
    date: new Intl.DateTimeFormat(locale, {
      timeZone: zone, weekday: 'short', month: 'short', day: 'numeric',
    }).format(instant),
    offset: new Intl.DateTimeFormat('en', {
      timeZone: zone, timeZoneName: 'shortOffset',
    }).formatToParts(instant).find(part => part.type === 'timeZoneName').value.replace(/^GMT[+-]0$/, 'GMT'),
  };
}

export function refreshClocks(root = document, instant = new Date()) {
  for (const row of root.querySelectorAll('[data-clock-zone]')) {
    try {
      const clock = formatClock(instant, row.dataset.clockZone);
      row.querySelector('[data-clock-time]').textContent = clock.time;
      row.querySelector('[data-clock-date]').textContent = clock.date + ' · ' + clock.offset;
    } catch {
      row.querySelector('[data-clock-time]').textContent = 'Invalid time zone';
      row.querySelector('[data-clock-date]').textContent = '';
    }
  }
}
