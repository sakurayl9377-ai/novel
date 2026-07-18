// Admin timestamps are stored as UTC. SQLite's `datetime('now')` omits the
// timezone suffix, so normalize those values before formatting for Beijing.
(() => {
  const timeZone = 'Asia/Shanghai';
  const formatter = new Intl.DateTimeFormat('zh-CN', {
    timeZone,
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });

  function parseServerTime(value) {
    if (!value) return null;
    const raw = String(value).trim();
    const iso = raw.replace(' ', 'T');
    const timestamp = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(iso) ? iso : `${iso}Z`;
    const date = new Date(timestamp);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function formatTime(value) {
    if (!value) return '-';
    const date = parseServerTime(value);
    if (!date) return String(value);
    const parts = Object.fromEntries(
      formatter
        .formatToParts(date)
        .filter((part) => part.type !== 'literal')
        .map((part) => [part.type, part.value]),
    );
    return `${parts.month}/${parts.day} ${parts.hour}:${parts.minute}`;
  }

  globalThis.NOVEL_ADMIN_TIME = Object.freeze({
    timeZone,
    parseServerTime,
    formatTime,
  });
})();
