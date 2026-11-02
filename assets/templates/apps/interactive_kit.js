/* OTIC app kit: makes the App Builder's phone templates work.
   Every tab, chip, heart, card, search bar, + button and bottom-bar icon
   does something, with motion that looks good on a screen recording.
   No network, no libraries. */
(function () {
  'use strict';
  var doc = document;
  var root = doc.documentElement;
  var phone = doc.querySelector('.phone') || doc.body;
  var home = phone.querySelector('.body') || phone;

  // Bottom-bar icons by meaning, for the screens they open.
  var NAV_NAMES = {
    '🏠': 'Home', '🔖': 'Saved', '🤍': 'Favourites', '🛍️': 'Cart', '⚙️': 'Settings', '📋': 'Reports',
    '➕': 'Add', '👤': 'Profile', '📚': 'My courses', '🔍': 'Search', '💬': 'Messages', '🧭': 'Discover',
    '🌾': 'Fields', '📦': 'Products', '💳': 'Payments', '📊': 'Stats', '🔔': 'Notifications', '▦': 'Dashboard'
  };

  // ── Storage (per app, best effort) ─────────────────────────────────────
  var appName = textOf(phone.querySelector('.nm, h1, .sh, .brand .nm')) || doc.title || 'app';
  var key = 'otic-app:' + appName;
  var state = { fav: {}, cart: [], dark: false, notify: true, offline: true };
  try {
    var saved = JSON.parse(localStorage.getItem(key) || 'null');
    if (saved) for (var k in saved) state[k] = saved[k];
  } catch (e) {}
  function save() {
    try { localStorage.setItem(key, JSON.stringify(state)); } catch (e) {}
  }
  if (state.dark) root.classList.add('ix-dark');

  // ── Helpers ────────────────────────────────────────────────────────────
  function $(sel, from) { return (from || doc).querySelector(sel); }
  function $$(sel, from) { return Array.prototype.slice.call((from || doc).querySelectorAll(sel)); }
  function el(tag, cls, text) {
    var n = doc.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function textOf(n) { return n ? n.textContent.replace(/\s+/g, ' ').trim() : ''; }
  function firstText(n) {
    if (!n) return '';
    for (var i = 0; i < n.childNodes.length; i++) {
      var t = n.childNodes[i].textContent.trim();
      if (t) return t;
    }
    return '';
  }
  function primary() {
    return getComputedStyle(root).getPropertyValue('--primary').trim() || '#4f46e5';
  }
  function parseNum(s) {
    var m = /([\d][\d,]*\.?\d*)/.exec(s || '');
    return m ? parseFloat(m[1].replace(/,/g, '')) : 0;
  }
  function money(sample, n) {
    var m = /^(\D*?)[\d][\d,]*\.?\d*(.*)$/.exec(sample || '');
    var dec = /\.\d/.test(sample || '') ? 2 : 0;
    var v = n.toLocaleString('en-US', { minimumFractionDigits: dec, maximumFractionDigits: dec });
    return m ? m[1] + v + m[2] : v;
  }

  // ── Toast, confetti, ripple ────────────────────────────────────────────
  var toastEl, toastTimer;
  function toast(msg) {
    if (!toastEl) { toastEl = el('div', 'ix-toast'); doc.body.appendChild(toastEl); }
    toastEl.textContent = msg;
    requestAnimationFrame(function () { toastEl.classList.add('on'); });
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('on'); }, 2200);
  }
  function confetti() {
    var colors = [primary(), '#f7c948', '#34d399', '#f472b6', '#60a5fa', '#fb923c'];
    for (var i = 0; i < 70; i++) {
      var c = el('i', 'ix-confetti');
      c.style.left = Math.random() * 100 + 'vw';
      c.style.background = colors[i % colors.length];
      c.style.setProperty('--dx', (Math.random() * 160 - 80) + 'px');
      c.style.setProperty('--rot', (Math.random() * 900 - 450) + 'deg');
      c.style.animationDuration = (1.4 + Math.random() * 1.4) + 's';
      c.style.animationDelay = Math.random() * 0.25 + 's';
      doc.body.appendChild(c);
      setTimeout(function (n) { n.remove(); }.bind(null, c), 3200);
    }
  }
  function heartBurst(x, y) {
    for (var i = 0; i < 5; i++) {
      var h = el('span', 'ix-heart-burst', '❤️');
      h.style.left = (x - 10 + (Math.random() * 30 - 15)) + 'px';
      h.style.top = (y - 10) + 'px';
      h.style.animationDelay = i * 0.06 + 's';
      doc.body.appendChild(h);
      setTimeout(function (n) { n.remove(); }.bind(null, h), 1200);
    }
  }
  function bump(n) {
    if (!n) return;
    n.classList.remove('ix-bump');
    void n.offsetWidth;
    n.classList.add('ix-bump');
  }

  var TAPPABLE = '.tab,.chip,.tile,.cat,.cbox,.switch>div,.item,.card,.course,.post,.row,.mentor,.stage,' +
    '.cta,.fab,.go,.promo,.banner button,.hero button,.feat li,.nav>div,.search,.bell,.ix-line,.ix-keys button';
  function prepTappable(scope) {
    $$(TAPPABLE, scope || doc).forEach(function (n) {
      if (n.dataset.ixTap) return;
      n.dataset.ixTap = '1';
      var cs = getComputedStyle(n);
      n.classList.add('ix-press');
      if (cs.position === 'static') { n.style.position = 'relative'; n.classList.add('ix-clip'); }
    });
  }
  doc.addEventListener('pointerdown', function (e) {
    var t = e.target.closest && e.target.closest('.ix-clip');
    if (!t) return;
    var r = t.getBoundingClientRect();
    var size = Math.max(r.width, r.height);
    var rip = el('span', 'ix-ripple');
    rip.style.width = rip.style.height = size + 'px';
    rip.style.left = (e.clientX - r.left - size / 2) + 'px';
    rip.style.top = (e.clientY - r.top - size / 2) + 'px';
    t.appendChild(rip);
    setTimeout(function () { rip.remove(); }, 650);
  });

  // ── Opening motion: content rises in, numbers count, bars grow ────────
  function entrance(scope) {
    var parts = [];
    $$('.hero,.head,.status', phone).forEach(function (n) { if (n.parentNode === phone) parts.push(n); });
    Array.prototype.forEach.call((scope || home).children, function (n) { parts.push(n); });
    parts.forEach(function (n, i) {
      n.classList.add('ix-in');
      n.style.animationDelay = Math.min(i * 70, 700) + 'ms';
    });
  }
  function countUp(scope) {
    $$('.v,.temp,.pct,.price,.pr,.stat .v,.totals .v', scope || phone).forEach(function (n) {
      if (n.children.length) return;
      var raw = n.textContent;
      var m = /^(\D*?)([\d][\d,]*\.?\d*)(.*)$/.exec(raw.trim());
      if (!m) return;
      var target = parseFloat(m[2].replace(/,/g, ''));
      if (!(target >= 1)) return;
      var dec = (m[2].split('.')[1] || '').length;
      var comma = m[2].indexOf(',') >= 0 || target >= 10000;
      var t0 = performance.now(), dur = 1100;
      function frame(now) {
        var p = Math.min(1, (now - t0) / dur);
        var e = 1 - Math.pow(1 - p, 3);
        var v = target * e;
        var s = comma ? v.toLocaleString('en-US', { minimumFractionDigits: dec, maximumFractionDigits: dec }) : v.toFixed(dec);
        n.textContent = m[1] + s + m[3];
        if (p < 1) requestAnimationFrame(frame); else n.textContent = raw;
      }
      requestAnimationFrame(frame);
    });
  }
  function growBars(scope) {
    $$('.bar i,.chart i,.spark i', scope || phone).forEach(function (n) {
      var w = n.style.width, h = n.style.height;
      if (w) { n.style.width = '0'; } if (h) { n.style.height = '0'; }
      n.classList.add('ix-grow');
      setTimeout(function () { if (w) n.style.width = w; if (h) n.style.height = h; }, 350);
    });
  }

  // Live clock in the status bar.
  var clock = $('.status span', phone);
  function tick() {
    if (!clock) return;
    var d = new Date();
    clock.textContent = d.getHours() + ':' + ('0' + d.getMinutes()).slice(-2);
  }
  tick(); setInterval(tick, 15000);

  // ── The app's main list: what search filters, + adds to, screens show ─
  var LISTS = ['.grid .item', '.cards .card', '.feed .post', '.plist .row', '.course', '.mentor', '.stage'];
  var KINDS = {
    '.grid .item': 'item', '.cards .card': 'card', '.feed .post': 'post',
    '.plist .row': 'row', '.course': 'course', '.mentor': 'mentor', '.stage': 'stage'
  };
  var ITEM_SEL = '.item,.cards .card,.post,.row,.course,.mentor,.stage';
  function mainList() {
    for (var i = 0; i < LISTS.length; i++) {
      var found = $$(LISTS[i], home);
      if (found.length) return { sel: LISTS[i], kind: KINDS[LISTS[i]], items: found };
    }
    return null;
  }
  function kindOf(n) {
    if (n.matches('.item')) return 'item';
    if (n.matches('.post')) return 'post';
    if (n.matches('.row')) return 'row';
    if (n.matches('.course')) return 'course';
    if (n.matches('.mentor')) return 'mentor';
    if (n.matches('.stage')) return 'stage';
    return 'card';
  }
  function info(n) {
    var pic = $('.pic,.ic,.av', n);
    return {
      emoji: firstText(pic) || '✨',
      title: textOf($('h4,h3,.nm,.label', n)) || 'Item',
      sub: textOf($('p,.meta,.tut,.by,.sb', n)),
      price: textOf($('.price,.pr', n))
    };
  }
  var NOUN = { item: 'product', row: 'product', course: 'course', post: 'post', card: 'field', mentor: 'mentor', stage: 'stage' };

  // ── Bottom sheet ───────────────────────────────────────────────────────
  var sheetEl, backEl;
  function closeSheet() {
    if (!sheetEl) return;
    var s = sheetEl, b = backEl;
    sheetEl = backEl = null;
    s.classList.remove('on'); b.classList.remove('on');
    setTimeout(function () { s.remove(); b.remove(); }, 380);
  }
  function openSheet(build) {
    closeSheet();
    backEl = el('div', 'ix-back');
    sheetEl = el('div', 'ix-sheet');
    sheetEl.appendChild(el('div', 'ix-grab'));
    build(sheetEl);
    backEl.addEventListener('click', closeSheet);
    doc.body.appendChild(backEl);
    doc.body.appendChild(sheetEl);
    prepTappable(sheetEl);
    var b = backEl, sh = sheetEl;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (sheetEl !== sh) return; // closed already
        b.classList.add('on'); sh.classList.add('on');
      });
    });
  }
  function button(label, cls, onClick) {
    var b = el('button', 'ix-btn' + (cls ? ' ' + cls : ''), label);
    b.type = 'button';
    b.addEventListener('click', onClick);
    return b;
  }

  // ── Cart and favourites ────────────────────────────────────────────────
  var cartNav = null, favNav = null;
  $$('.nav>div', phone).forEach(function (n) {
    var l = navLabel(n);
    if (/Cart|Payments|Sales/.test(l) && !cartNav) cartNav = n;
    if (/Saved|Favourites/.test(l) && !favNav) favNav = n;
  });
  function badge(host, count) {
    if (!host) return;
    host.classList.add('ix-badge-host');
    var b = $('.ix-badge', host);
    if (!count) { if (b) b.remove(); return; }
    if (!b) { b = el('span', 'ix-badge'); host.appendChild(b); }
    b.textContent = count;
    bump(b);
  }
  function cartCount() {
    return state.cart.reduce(function (a, c) { return a + c.qty; }, 0);
  }
  function addToCart(i) {
    var line = state.cart.filter(function (c) { return c.title === i.title; })[0];
    if (line) line.qty++; else state.cart.push({ title: i.title, emoji: i.emoji, price: i.price, qty: 1 });
    save();
    badge(cartNav, cartCount());
    toast(i.emoji + '  Added to cart');
  }
  function toggleFav(title, heartEl) {
    var on = !state.fav[title];
    if (on) state.fav[title] = true; else delete state.fav[title];
    save();
    if (heartEl) { heartEl.textContent = on ? '❤️' : '🤍'; bump(heartEl); }
    badge(favNav, Object.keys(state.fav).length);
    return on;
  }
  // Hearts and badges as last saved.
  $$('.heart', phone).forEach(function (h) {
    var item = h.closest(ITEM_SEL);
    if (item && state.fav[info(item).title]) h.textContent = '❤️';
  });
  badge(cartNav, cartCount());
  badge(favNav, Object.keys(state.fav).length);

  // ── Detail sheet for a card, product, course, post… ───────────────────
  function details(n) {
    var i = info(n), kind = kindOf(n);
    openSheet(function (s) {
      var hero = el('div', 'ix-hero', i.emoji);
      var pic = $('.pic', n);
      if (pic && pic.style.background) hero.style.background = pic.style.background;
      s.appendChild(hero);
      s.appendChild(el('h3', '', i.title));
      if (i.sub) s.appendChild(el('div', 'ix-sub', i.sub));
      if (i.price) s.appendChild(el('div', 'ix-price', i.price));
      var acts = el('div', 'ix-actions');

      if (kind === 'item' || kind === 'row') {
        acts.appendChild(button(state.fav[i.title] ? '❤️ Saved' : '🤍 Save', 'ghost', function () {
          var heart = $('.heart', n);
          var on = toggleFav(i.title, heart);
          this.textContent = on ? '❤️ Saved' : '🤍 Save';
        }));
        acts.appendChild(button('Add to cart', '', function () { addToCart(i); closeSheet(); }));
      } else if (kind === 'course') {
        var bar = $('.bar i', n);
        var pctEl = $('.pct', n);
        var now = bar ? parseNum(bar.style.width) : 0;
        var pr = el('div', 'ix-progress'); var fill = el('i'); pr.appendChild(fill);
        var label = el('div', 'ix-sub', 'Progress: ' + Math.round(now) + '%');
        s.appendChild(label);
        s.appendChild(pr);
        setTimeout(function () { fill.style.width = now + '%'; }, 60);
        acts.appendChild(button(now >= 100 ? 'Review again' : 'Continue lesson', '', function () {
          now = Math.min(100, now + 15);
          fill.style.width = now + '%';
          label.textContent = 'Progress: ' + now + '%';
          if (bar) bar.style.width = now + '%';
          if (pctEl) { pctEl.textContent = now + '%'; bump(pctEl); }
          if (now >= 100) { confetti(); toast('🎓  Course complete!'); this.textContent = 'Review again'; }
          else toast('📘  Lesson done — ' + now + '%');
        }));
      } else if (kind === 'post') {
        var likes = $('.likes', n);
        acts.appendChild(button(n.dataset.liked ? '♥ Liked' : '♡ Like', 'ghost', function (e) {
          like(likes, n, e.clientX, e.clientY);
          this.textContent = n.dataset.liked ? '♥ Liked' : '♡ Like';
        }));
        var box = el('div', 'ix-chat');
        var input = el('input', 'ix-field'); input.placeholder = 'Write a comment…';
        var send = button('Comment', '', function () {
          var v = input.value.trim(); if (!v) return;
          box.appendChild(el('div', 'ix-msg me', v)); input.value = '';
        });
        input.addEventListener('keydown', function (e) { if (e.key === 'Enter') send.click(); });
        s.appendChild(box); s.appendChild(input);
        acts.appendChild(send);
      } else if (kind === 'mentor') {
        var times = el('div', 'ix-times'), picked = null;
        ['Mon 9:00', 'Tue 14:00', 'Wed 10:30', 'Fri 16:00'].forEach(function (t) {
          var c = el('span', '', t);
          c.addEventListener('click', function () {
            $$('span', times).forEach(function (x) { x.classList.remove('on'); });
            c.classList.add('on'); picked = t;
          });
          times.appendChild(c);
        });
        s.appendChild(el('div', 'ix-sub', 'Pick a time'));
        s.appendChild(times);
        acts.appendChild(button('Book session', '', function () {
          if (!picked) { toast('Pick a time first'); return; }
          closeSheet(); confetti(); toast('📅  Booked with ' + i.title + ' · ' + picked);
        }));
      } else if (kind === 'stage') {
        var newEl = $('.new', n);
        acts.appendChild(button('Mark one done ✓', '', function () {
          var left = newEl ? parseNum(newEl.textContent) : 0;
          if (newEl && left > 0) { newEl.textContent = (left - 1) + ' new'; bump(newEl); }
          toast(left > 0 ? '✅  Order moved on' : 'Nothing new here');
          if (left <= 1) closeSheet();
        }));
      } else {
        var p = el('div', 'ix-progress'); var f = el('i'); p.appendChild(f);
        acts.appendChild(button('💧 Water now', '', function () {
          s.insertBefore(p, acts);
          setTimeout(function () { f.style.width = '100%'; }, 30);
          setTimeout(function () { closeSheet(); toast('💧  ' + i.title + ' watered'); }, 1000);
        }));
        acts.appendChild(button('📋 Report', 'ghost', function () { toast('📋  Report saved'); }));
      }
      s.appendChild(acts);
    });
  }

  function like(likes, post, x, y) {
    if (!likes) return;
    var n = parseNum(likes.textContent);
    var on = !post.dataset.liked;
    if (on) post.dataset.liked = '1'; else delete post.dataset.liked;
    likes.textContent = (on ? '♥ ' : '♡ ') + (on ? n + 1 : Math.max(0, n - 1));
    likes.style.color = on ? '#ef4444' : '';
    bump(likes);
    if (on && x) heartBurst(x, y);
  }

  // ── Add something new with the + button ───────────────────────────────
  function addNew() {
    var list = mainList();
    var noun = list ? NOUN[list.kind] : 'note';
    var withPrice = list && $('.price,.pr', list.items[0]);
    openSheet(function (s) {
      s.appendChild(el('h3', '', 'Add a new ' + noun));
      s.appendChild(el('div', 'ix-sub', 'It appears in ' + appName + ' straight away.'));
      var name = el('input', 'ix-field'); name.placeholder = 'Name';
      s.appendChild(name);
      var price = null;
      if (withPrice) {
        price = el('input', 'ix-field'); price.placeholder = 'Price'; price.inputMode = 'decimal';
        s.appendChild(price);
      }
      var acts = el('div', 'ix-actions');
      acts.appendChild(button('Cancel', 'ghost', closeSheet));
      acts.appendChild(button('Add', '', function () {
        var v = name.value.trim();
        if (!v) { name.focus(); toast('Give it a name'); return; }
        var made;
        if (list) {
          var src = list.items[0];
          made = src.cloneNode(true);
          made.removeAttribute('data-ix-tap');
          $$('[data-ix-tap]', made).forEach(function (x) { x.removeAttribute('data-ix-tap'); });
          $$('.ix-ripple,.ix-badge', made).forEach(function (x) { x.remove(); });
          var t = $('h4,h3,.nm,.label', made); if (t) t.textContent = v;
          var pr = $('.price,.pr', made);
          if (pr && price) pr.textContent = money(textOf($('.price,.pr', src)), parseNum(price.value) || 0);
          var heart = $('.heart', made); if (heart) heart.textContent = '🤍';
          var bar = $('.bar i', made); if (bar) bar.style.width = '0%';
          var pct = $('.pct', made); if (pct) pct.textContent = '0%';
          var likes = $('.likes', made); if (likes) likes.textContent = '♥ 0';
          var meta = $('.meta,p,.tut,.sb', made); if (meta) meta.textContent = 'Just added';
          src.parentNode.insertBefore(made, src);
        } else {
          var ul = $('.feat ul', home);
          if (!ul) return;
          made = el('li', '', v);
          ul.insertBefore(made, ul.firstChild);
        }
        made.classList.add('ix-pop');
        prepTappable(made.parentNode);
        closeSheet();
        showHome();
        setTimeout(function () { made.scrollIntoView({ behavior: 'smooth', block: 'center' }); }, 120);
        confetti();
        toast('✨  ' + v + ' added');
      }));
      s.appendChild(acts);
      setTimeout(function () { name.focus(); }, 400);
    });
  }

  // ── Search that filters the list ──────────────────────────────────────
  function activateSearch(box) {
    if (box.dataset.ixSearch) { $('input', box).focus(); return; }
    box.dataset.ixSearch = '1';
    var hint = box.textContent.replace('🔍', '').trim();
    box.textContent = '🔍 ';
    var input = el('input', 'ix-search');
    input.placeholder = hint || 'Search';
    box.appendChild(input);
    input.focus();
    var empty = el('div', 'ix-empty ix-hide', 'Nothing matches yet — try another word.');
    var list = mainList();
    if (list) list.items[list.items.length - 1].parentNode.appendChild(empty);
    input.addEventListener('input', function () {
      showHome();
      var q = input.value.toLowerCase().trim();
      var l = mainList(); if (!l) return;
      var shown = 0;
      l.items.forEach(function (n) {
        var hit = !q || n.textContent.toLowerCase().indexOf(q) >= 0;
        n.classList.toggle('ix-hide', !hit);
        if (hit) shown++;
      });
      empty.classList.toggle('ix-hide', shown > 0);
    });
  }

  // ── Tabs, chips, switches: pick one, the list reshuffles ──────────────
  function select(n) {
    var group = n.parentNode;
    $$(':scope > *', group).forEach(function (x) {
      if (x.matches('a')) return;
      x.classList.add('ix-sel');
      x.classList.toggle('on', x === n);
    });
    var list = mainList();
    if (!list || n.matches('.tile')) return;
    var parent = list.items[0].parentNode;
    var items = list.items.slice();
    var first = n === group.firstElementChild;
    items.sort(function () { return first ? 0 : Math.random() - 0.5; });
    items.forEach(function (x, i) {
      x.classList.remove('ix-hide', 'ix-in', 'ix-pop');
      if (!first && i % 3 === 2) x.classList.add('ix-hide');
      parent.appendChild(x);
      void x.offsetWidth;
      x.classList.add('ix-in');
      x.style.animationDelay = i * 60 + 'ms';
    });
    var empty = $('.ix-empty', parent); if (empty) parent.appendChild(empty);
  }

  // ── Tiles: a working mini screen (a till for "Register") ──────────────
  function tileScreen(tile) {
    var label = textOf($('b', tile)) || textOf(tile);
    var icon = firstText($('span', tile)) || '📋';
    if (/register|till|sell|checkout/i.test(label)) return register();
    var rows = { Orders: ['Order #1042', 'Order #1043', 'Order #1044'],
      Invoices: ['Invoice INV-221', 'Invoice INV-222'], Customers: ['Amina N.', 'Joseph K.', 'Grace A.'],
      Settings: [] };
    if (/settings/i.test(label)) { openSheet(function (s) { s.appendChild(el('h3', '', '⚙️ Settings')); settings(s); }); return; }
    miniList(icon + ' ' + label, rows[label] || ['First entry', 'Second entry'], icon);
  }
  function miniList(title, entries, icon) {
    openSheet(function (s) {
      s.appendChild(el('h3', '', title));
      s.appendChild(el('div', 'ix-sub', entries.length + ' saved'));
      var list = el('div', 'ix-list');
      function add(t, fresh) {
        var line = el('div', 'ix-line' + (fresh ? ' ix-pop' : ''));
        line.appendChild(el('div', 'ix-ico', icon));
        line.appendChild(el('div', 'ix-t', t));
        line.appendChild(el('div', 'ix-r', '›'));
        list.insertBefore(line, fresh ? list.firstChild : null);
        prepTappable(list);
      }
      entries.forEach(function (t) { add(t); });
      s.appendChild(list);
      var input = el('input', 'ix-field'); input.placeholder = 'Add new…'; input.style.marginTop = '14px';
      s.appendChild(input);
      var go = button('Add', '', function () {
        var v = input.value.trim(); if (!v) return;
        add(v, true); input.value = '';
        $('.ix-sub', s).textContent = list.children.length + ' saved';
        toast('✨  Saved');
      });
      input.addEventListener('keydown', function (e) { if (e.key === 'Enter') go.click(); });
      var acts = el('div', 'ix-actions'); acts.appendChild(go); s.appendChild(acts);
    });
  }
  function register() {
    var totalEl = $$('.totals .v', phone)[1];
    var receiptsEl = $$('.totals .v', phone)[0];
    var sample = textOf(totalEl) || '1,000';
    var goods = [['🍞', 'Bread', 2000], ['🥛', 'Milk', 1500], ['🍚', 'Rice 1kg', 4000], ['🧃', 'Juice', 2500],
      ['🥚', 'Eggs (tray)', 12000], ['🧼', 'Soap', 3000]];
    var basket = [];
    openSheet(function (s) {
      s.appendChild(el('h3', '', '🧾 Register'));
      s.appendChild(el('div', 'ix-sub', 'Tap goods to add them to the receipt.'));
      var keys = el('div', 'ix-keys');
      var lines = el('div', 'ix-list');
      var total = el('div', 'ix-total');
      function render() {
        lines.textContent = '';
        var sum = 0;
        basket.forEach(function (b) {
          sum += b[2] * b[3];
          var line = el('div', 'ix-line');
          line.appendChild(el('div', 'ix-ico', b[0]));
          line.appendChild(el('div', 'ix-t', b[1] + ' × ' + b[3]));
          line.appendChild(el('div', 'ix-r', money(sample, b[2] * b[3])));
          lines.appendChild(line);
        });
        total.textContent = '';
        total.appendChild(el('span', '', 'Total'));
        var v = el('span', '', money(sample, sum)); total.appendChild(v); bump(v);
        return sum;
      }
      goods.forEach(function (g) {
        var b = el('button', '');
        b.type = 'button';
        b.appendChild(el('span', '', g[0]));
        b.appendChild(doc.createTextNode(g[1]));
        b.appendChild(el('small', '', money(sample, g[2])));
        b.addEventListener('click', function () {
          var line = basket.filter(function (x) { return x[1] === g[1]; })[0];
          if (line) line[3]++; else basket.push([g[0], g[1], g[2], 1]);
          render();
        });
        keys.appendChild(b);
      });
      s.appendChild(keys); s.appendChild(lines); s.appendChild(total);
      render();
      var acts = el('div', 'ix-actions');
      acts.appendChild(button('Clear', 'ghost', function () { basket = []; render(); }));
      acts.appendChild(button('Charge', '', function () {
        var sum = render();
        if (!sum) { toast('Add something first'); return; }
        if (totalEl) { totalEl.textContent = money(sample, parseNum(totalEl.textContent) + sum); bump(totalEl); }
        if (receiptsEl) { receiptsEl.textContent = String(parseNum(receiptsEl.textContent) + 1); bump(receiptsEl); }
        closeSheet(); confetti(); toast('✅  Paid ' + money(sample, sum));
      }));
      s.appendChild(acts);
    });
  }

  // ── Bottom bar: every icon opens its own screen ───────────────────────
  function navLabel(n) {
    var own = '';
    for (var i = 0; i < n.childNodes.length; i++) {
      if (n.childNodes[i].nodeType === 3) own += n.childNodes[i].textContent;
    }
    own = own.trim();
    var icon = firstText($('span', n)) || textOf(n);
    if (own && !NAV_NAMES[own]) return own;
    return NAV_NAMES[icon] || NAV_NAMES[own] || own || 'Screen';
  }
  var screenEl = null;
  function showHome() {
    if (screenEl) { screenEl.remove(); screenEl = null; }
    home.classList.remove('ix-hide');
    var first = $('.nav>div', phone);
    if (first) $$('.nav>div', phone).forEach(function (x) { x.classList.toggle('on', x === first); });
  }
  function showScreen(label, navItem) {
    if (screenEl) screenEl.remove();
    home.classList.add('ix-hide');
    screenEl = el('div', 'ix-screen');
    screenEl.appendChild(el('h2', 'ix-title', label));
    home.parentNode.insertBefore(screenEl, home.nextSibling);
    $$('.nav>div', phone).forEach(function (x) { x.classList.toggle('on', x === navItem); });
    return screenEl;
  }
  function lineFor(i, right) {
    var line = el('div', 'ix-line');
    line.appendChild(el('div', 'ix-ico', i.emoji));
    var t = el('div', 'ix-t', i.title);
    if (i.sub) t.appendChild(el('div', 'ix-s', i.sub));
    line.appendChild(t);
    if (right) line.appendChild(el('div', 'ix-r', right));
    return line;
  }
  function settings(s) {
    [['Dark mode', 'dark'], ['Notifications', 'notify'], ['Works offline', 'offline']].forEach(function (o) {
      var row = el('div', 'ix-row-toggle', o[0]);
      var sw = el('div', 'ix-switch' + (state[o[1]] ? ' on' : ''));
      sw.addEventListener('click', function () {
        state[o[1]] = !state[o[1]]; save();
        sw.classList.toggle('on', state[o[1]]);
        if (o[1] === 'dark') root.classList.toggle('ix-dark', state.dark);
        toast(o[0] + (state[o[1]] ? ' on' : ' off'));
      });
      row.appendChild(sw);
      row.style.marginBottom = '10px';
      s.appendChild(row);
    });
  }
  function navTap(n) {
    if (n.matches('.fab')) { addNew(); return; }
    var label = navLabel(n);
    if (label === 'Home' || n === $('.nav>div', phone)) { showHome(); entrance(); return; }
    if (label === 'Add') { addNew(); return; }
    var s = showScreen(label, n);
    var list = mainList();
    var items = list ? list.items.map(info) : [];

    if (/Favourites|Saved/.test(label)) {
      var favs = items.filter(function (i) { return state.fav[i.title]; });
      var box = el('div', 'ix-list');
      favs.forEach(function (i) { box.appendChild(lineFor(i, '❤️')); });
      s.appendChild(favs.length ? box : el('div', 'ix-empty', 'Tap 🤍 on anything to keep it here.'));
    } else if (/Cart|Payments|Sales/.test(label)) {
      cartScreen(s);
    } else if (/Profile|Settings/.test(label)) {
      var prof = el('div', 'ix-profile');
      prof.appendChild(el('div', 'ix-avatar', (appName[0] || 'A').toUpperCase()));
      var who = el('div');
      who.appendChild(el('div', '', appName)).style.fontWeight = '800';
      who.appendChild(el('div', 'ix-sub', 'Signed in · works offline'));
      prof.appendChild(who);
      s.appendChild(prof);
      var chips = el('div', 'ix-chips');
      [[Object.keys(state.fav).length, 'Saved'], [cartCount(), 'In cart'], [items.length, 'Items']].forEach(function (c) {
        var d = el('div'); d.appendChild(el('b', '', String(c[0]))); d.appendChild(el('span', '', c[1])); chips.appendChild(d);
      });
      s.appendChild(chips);
      settings(s);
    } else if (/Stats|Reports|Dashboard/.test(label)) {
      var bars = el('div', 'ix-bars');
      for (var b = 0; b < 7; b++) bars.appendChild(el('i'));
      s.appendChild(bars);
      s.appendChild(el('div', 'ix-sub', 'This week, day by day'));
      setTimeout(function () {
        $$('i', bars).forEach(function (x, i) { x.style.height = (30 + ((i * 37) % 60)) + '%'; });
      }, 80);
      var sum = el('div', 'ix-list');
      sum.appendChild(lineFor({ emoji: '📈', title: 'Best day', sub: 'Thursday' }, '+24%'));
      sum.appendChild(lineFor({ emoji: '🗂️', title: 'Items tracked', sub: appName }, String(items.length)));
      s.appendChild(sum);
    } else if (/Notifications/.test(label)) {
      notifications(s);
    } else if (/Messages|Communities/.test(label)) {
      chatScreen(s);
    } else if (/Search/.test(label)) {
      var input = el('input', 'ix-field'); input.placeholder = 'Search ' + appName;
      var res = el('div', 'ix-list');
      function run() {
        res.textContent = '';
        var q = input.value.toLowerCase().trim();
        items.filter(function (i) { return !q || (i.title + ' ' + i.sub).toLowerCase().indexOf(q) >= 0; })
          .forEach(function (i) { res.appendChild(lineFor(i, '›')); });
        if (!res.children.length) res.appendChild(el('div', 'ix-empty', 'No matches yet.'));
      }
      input.addEventListener('input', run);
      s.appendChild(input); s.appendChild(res); run();
      setTimeout(function () { input.focus(); }, 200);
    } else {
      var all = el('div', 'ix-list');
      items.forEach(function (i) { all.appendChild(lineFor(i, i.price || '›')); });
      s.appendChild(items.length ? all : el('div', 'ix-empty', 'Nothing here yet.'));
      var add = button('+ Add new', '', addNew); add.style.marginTop = '14px'; add.style.width = '100%';
      s.appendChild(add);
    }
    prepTappable(s);
  }
  function cartScreen(s) {
    var box = el('div', 'ix-list');
    var total = el('div', 'ix-total');
    var sample = (state.cart[0] && state.cart[0].price) || '';
    function render() {
      box.textContent = '';
      var sum = 0;
      state.cart.forEach(function (c, idx) {
        sum += parseNum(c.price) * c.qty;
        var line = lineFor({ emoji: c.emoji, title: c.title, sub: c.price });
        var q = el('div', 'ix-qty');
        var minus = el('button', '', '−'); var plus = el('button', '', '+');
        minus.addEventListener('click', function () { c.qty--; if (c.qty <= 0) state.cart.splice(idx, 1); save(); badge(cartNav, cartCount()); render(); });
        plus.addEventListener('click', function () { c.qty++; save(); badge(cartNav, cartCount()); render(); });
        q.appendChild(minus); q.appendChild(el('b', '', String(c.qty))); q.appendChild(plus);
        line.appendChild(q);
        box.appendChild(line);
      });
      total.textContent = '';
      total.appendChild(el('span', '', 'Total'));
      total.appendChild(el('span', '', sample ? money(sample, sum) : String(sum)));
      if (!state.cart.length) box.appendChild(el('div', 'ix-empty', 'Your cart is empty — add something from Home.'));
    }
    render();
    s.appendChild(box); s.appendChild(total);
    s.appendChild(button('Checkout', '', function () {
      if (!state.cart.length) { toast('Your cart is empty'); return; }
      state.cart = []; save(); badge(cartNav, 0); render();
      confetti(); toast('🎉  Order placed!');
    }));
  }
  function notifications(s) {
    var box = el('div', 'ix-list');
    [['🔔', 'Welcome to ' + appName, 'Just now'], ['✅', 'Your data is saved on this device', '2 min ago'],
      ['⭐', 'Tip: tap + to add something new', 'Today']].forEach(function (n, i) {
      var line = lineFor({ emoji: n[0], title: n[1], sub: n[2] });
      line.classList.add('ix-in'); line.style.animationDelay = i * 90 + 'ms';
      box.appendChild(line);
    });
    s.appendChild(box);
  }
  function chatScreen(s) {
    var chat = el('div', 'ix-chat');
    chat.appendChild(el('div', 'ix-msg them', 'Hi! 👋 Welcome to ' + appName + '. How can we help?'));
    var input = el('input', 'ix-field'); input.placeholder = 'Type a message…';
    var replies = ['Great question! 😊', 'Sure — we can do that.', 'Thanks! 👍', 'Got it, on it now. 🚀'];
    var send = button('Send', '', function () {
      var v = input.value.trim(); if (!v) return;
      chat.appendChild(el('div', 'ix-msg me', v)); input.value = '';
      var typing = el('div', 'ix-typing', 'typing…'); chat.appendChild(typing);
      setTimeout(function () {
        typing.remove();
        chat.appendChild(el('div', 'ix-msg them', replies[chat.children.length % replies.length]));
      }, 900);
    });
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') send.click(); });
    s.appendChild(chat); s.appendChild(input); s.appendChild(send);
  }

  // ── One click handler for the whole app ───────────────────────────────
  doc.addEventListener('click', function (e) {
    var t = e.target;
    if (!t.closest || t.closest('.ix-sheet')) return;
    var n;
    if ((n = t.closest('a[href="#"]'))) {
      e.preventDefault();
      var navs = $$('.nav>div', phone);
      var target = navs.filter(function (x) { return !/Home|Profile|Settings|Add/.test(navLabel(x)) && !x.matches('.fab'); })[0];
      var s = showScreen(textOf(n.parentNode.querySelector('h2')) || 'All', target);
      var list = mainList();
      var box = el('div', 'ix-list');
      (list ? list.items.map(info) : []).forEach(function (i) { box.appendChild(lineFor(i, i.price || '›')); });
      s.appendChild(box);
      prepTappable(s);
      return;
    }
    if ((n = t.closest('.heart'))) {
      var item = n.closest(ITEM_SEL);
      if (toggleFav(item ? info(item).title : 'Item', n)) heartBurst(e.clientX, e.clientY);
      return;
    }
    if ((n = t.closest('.likes'))) { like(n, n.closest('.post'), e.clientX, e.clientY); return; }
    if ((n = t.closest('.search'))) { activateSearch(n); return; }
    if ((n = t.closest('.bell'))) {
      bump(n); n.classList.remove('ix-shake'); void n.offsetWidth; n.classList.add('ix-shake');
      openSheet(function (s) { s.appendChild(el('h3', '', '🔔 Notifications')); notifications(s); });
      return;
    }
    if ((n = t.closest('.nav>div'))) { navTap(n); return; }
    if ((n = t.closest('.fab'))) { addNew(); return; }
    if ((n = t.closest('.ix-line'))) { bump(n); return; }
    if ((n = t.closest('.tile'))) {
      select(n);
      if ($('b', n)) tileScreen(n); else { countUp(n); bump(n); }
      return;
    }
    if ((n = t.closest('.tab,.chip,.switch>div,.cat,.cbox'))) { select(n); return; }
    if ((n = t.closest('.go'))) {
      bump(n);
      var card = n.closest('.card');
      if (card) { growBars(card); countUp(card); }
      toast('📊  Updated just now');
      return;
    }
    if ((n = t.closest('.stage,.item,.cards .card,.post,.row,.course,.mentor'))) { details(n); return; }
    if ((n = t.closest('.feat li'))) {
      n.classList.toggle('ix-done');
      var lis = $$('.feat li', home), done = $$('.feat li.ix-done', home).length;
      if (done === lis.length && lis.length) { confetti(); toast('🏁  Everything done!'); }
      return;
    }
    if ((n = t.closest('button,.cta,.promo,.weather'))) {
      bump(n);
      confetti();
      toast(n.matches('.promo') ? '🎁  Offer unlocked!' : '🚀  Let\'s go!');
      var first = mainList();
      if (first) setTimeout(function () { first.items[0].scrollIntoView({ behavior: 'smooth', block: 'center' }); }, 400);
      return;
    }
  });

  // ── Start ──────────────────────────────────────────────────────────────
  prepTappable(doc);
  entrance();
  setTimeout(function () { countUp(); }, 250);
  growBars();
})();
