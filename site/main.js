// Ballast — ballast.ing
// Two jobs: copy buttons, and one demonstration of a container going down.

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

  /* --- one status change, so the menu bar badge has a reason to appear ----
     Plays once rather than looping: a slow repeating animation in the corner
     of the eye is exactly the thing reduced-motion guidance warns about. */

  const stage   = document.querySelector('.stage');
  const row     = document.getElementById('row-jellyfin');
  const glyph   = document.getElementById('jf-glyph');
  const actions = document.getElementById('jf-actions');
  const summary = document.getElementById('pop-summary');
  const item    = document.getElementById('mb-item');
  const replay  = document.getElementById('replay');

  if (!stage || !row || !glyph || !summary || !item) return;

  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const use = (host, id) => {
    host.innerHTML = '<svg><use href="#' + id + '"/></svg>';
  };

  const setDown = () => {
    glyph.style.color = 'var(--bad)';
    use(glyph, 's-bad');
    summary.textContent = '11 up · 1 needs attention';
    item.innerHTML =
      '<svg id="mb-glyph"><use href="#m-bad"/></svg><span class="count">1</span>';
    item.classList.add('is-alert');
    // A stopped container offers start, not restart and stop.
    actions.innerHTML =
      '<button tabindex="-1"><svg><use href="#i-play"/></svg></button>' +
      '<button tabindex="-1"><svg><use href="#i-open"/></svg></button>';
    row.dataset.state = 'down';
  };

  const setUp = () => {
    glyph.style.color = 'var(--ok)';
    use(glyph, 's-ok');
    summary.textContent = '12 up';
    item.classList.remove('is-alert');
    item.innerHTML =
      '<svg id="mb-glyph"><use href="#m-ok"/></svg><span class="count">1</span>';
    actions.innerHTML =
      '<button tabindex="-1"><svg><use href="#i-restart"/></svg></button>' +
      '<button tabindex="-1"><svg><use href="#i-stop"/></svg></button>' +
      '<button tabindex="-1"><svg><use href="#i-open"/></svg></button>';
    delete row.dataset.state;
  };

  let played = false;
  const play = () => {
    if (played) return;
    played = true;
    setTimeout(() => {
      setDown();
      if (replay) replay.hidden = false;
    }, reduced ? 0 : 2200);
  };

  if (reduced) {
    play();
  } else if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) { play(); io.disconnect(); }
      });
    }, { threshold: 0.35 });
    io.observe(stage);
  } else {
    play();
  }

  if (replay) {
    replay.addEventListener('click', () => {
      replay.hidden = true;
      setUp();
      played = false;
      play();
    });
  }
})();
