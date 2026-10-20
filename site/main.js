// Ballast — ballast.ing
// Copy buttons, and a menu you can actually poke at: rows go down, come back,
// and show the in-flight state the app shows while Docker works.

(() => {
  'use strict';

  /* --- copy buttons ------------------------------------------------------ */

  document.querySelectorAll('.copy').forEach((btn) => {
    const label = btn.querySelector('span');
    const original = label.textContent;
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy);
        label.textContent = 'Copied';
      } catch {
        label.textContent = 'Press ⌘C';
      }
      setTimeout(() => { label.textContent = original; }, 1600);
    });
  });

  /* --- the menu ---------------------------------------------------------- */

  const list    = document.querySelector('.pop-list');
  const stage   = document.querySelector('.stage');
  const summary = document.getElementById('pop-summary');
  const item     = document.getElementById('mb-item');
  const replay  = document.getElementById('replay');
  if (!list || !stage || !summary || !item) return;

  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Ten rows are visible; the other two are below the fold of a scrolling list.
  const TOTAL = 12;

  const glyph = (id) => '<svg><use href="#' + id + '"/></svg>';
  const control = (act, icon) =>
    '<button type="button" tabindex="-1" data-act="' + act + '" aria-hidden="true">' +
    glyph(icon) + '</button>';

  const rowsDown = () => list.querySelectorAll('.row[data-state="down"]').length;

  // The header summary and the menu bar item both read off the same count, so
  // they can never disagree.
  const sync = () => {
    const down = rowsDown();
    const up = TOTAL - down;
    summary.textContent = down === 0
      ? up + ' up'
      : up + ' up · ' + down + (down === 1 ? ' needs' : ' need') + ' attention';
    item.innerHTML = glyph(down === 0 ? 'm-ok' : 'm-bad') +
      '<span class="count">' + down + '</span>';
    item.classList.toggle('is-alert', down > 0);
  };

  const setUp = (row) => {
    const g = row.querySelector('.row-glyph');
    g.style.color = 'var(--ok)';
    g.innerHTML = glyph('s-ok');
    row.querySelector('.row-actions').innerHTML =
      control('restart', 'a-restart') + control('stop', 'a-stop') +
      (row.dataset.port ? control('open', 'a-open') : '');
    delete row.dataset.state;
    sync();
  };

  const setDown = (row) => {
    const g = row.querySelector('.row-glyph');
    g.style.color = 'var(--bad)';
    g.innerHTML = glyph('s-bad');
    // A stopped container offers start — there is nothing to restart or stop.
    row.querySelector('.row-actions').innerHTML = control('start', 'a-start');
    row.dataset.state = 'down';
    sync();
  };

  // What each control says while it waits, and where the row lands afterwards.
  const ACTIONS = {
    restart: { label: 'restarting', ms: 1400, then: setUp },
    stop:    { label: 'stopping',   ms: 1100, then: setDown },
    start:   { label: 'starting',   ms: 1300, then: setUp },
  };

  const run = (row, act) => {
    const spec = ACTIONS[act];
    if (!spec || row.classList.contains('is-busy')) return;
    row.querySelector('.busy-label').textContent = spec.label;
    row.classList.add('is-busy');
    setTimeout(() => {
      row.classList.remove('is-busy');
      spec.then(row);
    }, spec.ms);
  };

  list.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    e.preventDefault();
    const row = btn.closest('.row');
    if (row) run(row, btn.dataset.act);
  });

  // Remember which rows have somewhere to open, so start/stop can restore the
  // right set of controls.
  list.querySelectorAll('.row').forEach((row) => {
    if (row.querySelector('[data-act="open"]')) row.dataset.port = '1';
  });

  /* --- one unprompted failure, so the badge has a reason to appear --------
     Plays once rather than looping: a slow repeat in the corner of the eye is
     the thing reduced-motion guidance warns about. */

  const jellyfin = document.getElementById('row-jellyfin');
  let played = false;

  const play = () => {
    if (played || !jellyfin) return;
    played = true;
    setTimeout(() => {
      setDown(jellyfin);
      if (replay) replay.hidden = false;
    }, reduced ? 0 : 2200);
  };

  if (reduced) {
    play();
  } else if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { play(); io.disconnect(); } });
    }, { threshold: 0.35 });
    io.observe(stage);
  } else {
    play();
  }

  if (replay) {
    replay.addEventListener('click', () => {
      replay.hidden = true;
      list.querySelectorAll('.row[data-state="down"]').forEach(setUp);
      played = false;
      play();
    });
  }

  sync();
})();
