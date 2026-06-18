/* =====================================================================
   LinPlayer · Blingee Pixel runtime
   - bottom-right pixel music player (autoplay + unlock-on-interaction)
   - twinkling glitter overlay
   - drifting cherry-blossom petals
   - playful tab-title swap on visibility change
   ===================================================================== */
(function () {
  "use strict";

  var TRACK_PATH = "/assets/audio/Xploshi-NewYou.flac";
  var TRACK_NAME = "Xploshi — New You";
  var leaveTitle = "烸個亾洧着屬纡洎己哋杺凊";
  var returnTitle = "莈洧邇啲ㄖ孓，莪過啲並鈈恏";
  var originalTitle = document.title;
  var restoreTimer = null;
  var reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- tab title play ---------- */
  function restoreOriginalTitle() {
    window.clearTimeout(restoreTimer);
    restoreTimer = window.setTimeout(function () {
      document.title = originalTitle;
    }, 2400);
  }

  function handleVisibilityChange() {
    window.clearTimeout(restoreTimer);
    if (document.hidden) {
      document.title = leaveTitle;
      return;
    }
    document.title = returnTitle;
    restoreOriginalTitle();
  }

  /* ---------- animated glitter wallpaper (3-frame twinkle, behind content) ---------- */
  function mountGlitterBg() {
    if (document.getElementById("glitter-bg")) {
      return;
    }
    var bg = document.createElement("div");
    bg.id = "glitter-bg";
    bg.setAttribute("aria-hidden", "true");
    for (var i = 1; i <= 3; i++) {
      var frame = document.createElement("div");
      frame.className = "gframe gframe--" + i;
      bg.appendChild(frame);
    }
    document.body.appendChild(bg);
  }

  /* ---------- light foreground sparkle (twinkles over content) ---------- */
  function mountGlitter() {
    if (reduceMotion || document.getElementById("bling-layer")) {
      return;
    }
    var layer = document.createElement("div");
    layer.id = "bling-layer";
    layer.setAttribute("aria-hidden", "true");

    var starColors = ["#ffffff", "#fff49d", "#ff79c6", "#6fe6ff", "#c89bff"];
    var starCount = window.innerWidth < 600 ? 12 : 22;
    for (var i = 0; i < starCount; i++) {
      var star = document.createElement("span");
      star.className = "bling-star";
      var size = 6 + Math.floor(Math.random() * 12);
      star.style.left = (Math.random() * 100).toFixed(2) + "%";
      star.style.top = (Math.random() * 100).toFixed(2) + "%";
      star.style.width = size + "px";
      star.style.height = size + "px";
      star.style.color = starColors[i % starColors.length];
      star.style.animationDelay = (Math.random() * 2.6).toFixed(2) + "s";
      star.style.animationDuration = (1.6 + Math.random() * 1.6).toFixed(2) + "s";
      layer.appendChild(star);
    }
    document.body.appendChild(layer);
  }

  /* ---------- pixel music player ---------- */
  var ICON_PLAY = "▶";
  var ICON_PAUSE = "❙❙";

  /* playback state persists across page loads (multi-page static site) */
  var STORE_KEY = "pixelPlayer.v1";
  function loadState() {
    try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; }
    catch (e) { return {}; }
  }
  function saveState(patch) {
    try {
      var s = loadState();
      for (var k in patch) {
        if (Object.prototype.hasOwnProperty.call(patch, k)) s[k] = patch[k];
      }
      localStorage.setItem(STORE_KEY, JSON.stringify(s));
    } catch (e) { /* storage blocked — degrade gracefully */ }
  }

  function mountPlayer() {
    if (document.querySelector(".pixel-player")) {
      return;
    }

    var player = document.createElement("section");
    player.className = "pixel-player";
    player.setAttribute("aria-label", "Blingee 像素播放器");
    player.innerHTML =
      '<div class="pixel-player__deck">' +
      '  <div class="pixel-player__disc" aria-hidden="true"></div>' +
      '  <div class="pixel-player__info">' +
      '    <div class="pixel-player__label">NOW PLAYING</div>' +
      '    <div class="pixel-player__marquee"><span>' + TRACK_NAME + " ★ " + TRACK_NAME + "</span></div>" +
      '    <div class="pixel-player__eq" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>' +
      "  </div>" +
      "</div>" +
      '<div class="pixel-player__controls">' +
      '  <button type="button" class="pixel-player__btn" data-act="toggle" aria-label="播放 / 暂停">' + ICON_PLAY + "</button>" +
      '  <input class="pixel-player__vol" type="range" min="0" max="100" value="34" aria-label="音量">' +
      "</div>" +
      '<div class="pixel-player__state" aria-live="polite">loading</div>';

    var saved = loadState();

    var audio = document.createElement("audio");
    audio.id = "pixel-dream-audio";
    audio.loop = true;
    audio.preload = "auto";
    audio.volume = (typeof saved.volume === "number") ? saved.volume : 0.34;
    audio.src = TRACK_PATH;
    audio.setAttribute("aria-hidden", "true");
    audio.style.display = "none";

    var btn = player.querySelector('[data-act="toggle"]');
    var stateNode = player.querySelector(".pixel-player__state");
    var volume = player.querySelector(".pixel-player__vol");
    var unlockEvents = ["pointerdown", "keydown", "touchstart"];
    var wantsPlay = saved.paused !== true; // honour the user's last intent
    var seeked = false;

    volume.value = Math.round(audio.volume * 100);

    var labels = {
      loading: "loading",
      playing: "playing ♪",
      paused: "paused",
      blocked: "tap to play",
      missing: "track missing"
    };

    function setState(state) {
      player.dataset.state = state;
      stateNode.textContent = labels[state] || state;
      btn.textContent = state === "playing" ? ICON_PAUSE : ICON_PLAY;
    }

    function paintVolume() {
      volume.style.setProperty("--vol", volume.value + "%");
    }

    // resume from the saved position; retries on metadata if not seekable yet
    function restoreTime() {
      if (seeked) return;
      var t = saved.time;
      if (!(typeof t === "number" && isFinite(t) && t > 0.5)) { seeked = true; return; }
      try {
        audio.currentTime = t;
        seeked = true;
      } catch (e) { /* not seekable yet — loadedmetadata will retry */ }
    }

    function persistTime() {
      if (audio.currentTime > 0) saveState({ time: audio.currentTime });
    }

    function playAudio() {
      restoreTime();
      var p = audio.play();
      if (p && typeof p.then === "function") {
        p.then(function () {
          setState("playing");
          removeUnlockListeners();
        }).catch(function () {
          setState("blocked");
        });
      }
    }

    function pauseAudio() {
      audio.pause();
      setState("paused");
      persistTime();
    }

    function handleUnlock() {
      if (wantsPlay && audio.paused && player.dataset.state !== "missing") {
        playAudio();
      }
    }

    function addUnlockListeners() {
      unlockEvents.forEach(function (evt) {
        document.addEventListener(evt, handleUnlock, { passive: true });
      });
    }
    function removeUnlockListeners() {
      unlockEvents.forEach(function (evt) {
        document.removeEventListener(evt, handleUnlock, { passive: true });
      });
    }

    if (audio.readyState >= 1) { restoreTime(); }
    audio.addEventListener("loadedmetadata", restoreTime);

    audio.addEventListener("playing", function () {
      setState("playing");
      saveState({ paused: false });
    });
    audio.addEventListener("pause", function () {
      if (audio.currentTime > 0 && !audio.ended) setState("paused");
    });
    audio.addEventListener("error", function () { setState("missing"); });

    // keep the saved position fresh, and flush it before leaving the page
    var lastSave = 0;
    audio.addEventListener("timeupdate", function () {
      var now = Date.now();
      if (now - lastSave > 1000) { lastSave = now; persistTime(); }
    });
    window.addEventListener("pagehide", persistTime);
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) persistTime();
    });

    btn.addEventListener("click", function () {
      if (player.dataset.state === "missing") return;
      if (audio.paused) {
        wantsPlay = true;
        saveState({ paused: false });
        playAudio();
      } else {
        wantsPlay = false;
        saveState({ paused: true });
        pauseAudio();
      }
    });

    volume.addEventListener("input", function () {
      audio.volume = Math.min(1, Math.max(0, volume.value / 100));
      paintVolume();
      saveState({ volume: audio.volume });
    });

    document.body.appendChild(audio);
    document.body.appendChild(player);

    paintVolume();

    if (wantsPlay) {
      setState("loading");
      addUnlockListeners();
      playAudio();
    } else {
      // user paused earlier — stay paused but keep the saved position
      setState("paused");
      restoreTime();
    }
  }

  /* ---------- PJAX: swap content without reloading, so audio never stops ---------- */
  var PERSIST_IDS = ["modalSearch", "scroll-top-button"];

  function mountPjax() {
    if (!window.history || !history.pushState || !window.fetch || !window.DOMParser ||
        !window.Fluid || !Fluid.boot || !Fluid.boot.refresh) {
      return; // unsupported — links just do normal full navigations
    }

    var NP = window.NProgress || null;
    var loading = false;

    // pull the search modal + scroll-top button out of the swap zone so their
    // existing bindings survive (they're position:fixed, so location is cosmetic)
    PERSIST_IDS.forEach(function (id) {
      var el = document.getElementById(id);
      if (el && el.parentNode !== document.body) document.body.appendChild(el);
    });

    function updateNavActive() {
      var path = location.pathname;
      var items = document.querySelectorAll("#navbar .nav-item");
      for (var i = 0; i < items.length; i++) {
        var a = items[i].querySelector(".nav-link");
        var href = a ? a.getAttribute("href") : "";
        var on = href === "/" ? path === "/" :
          (href && href !== "javascript:;" && path.indexOf(href.replace(/\/$/, "")) === 0);
        items[i].classList.toggle("active", !!on);
      }
    }

    function afterSwap(url) {
      try { Fluid.boot.refresh(); } catch (e) { /* keep going */ }
      updateNavActive();
      var hash = url.indexOf("#") >= 0 ? url.slice(url.indexOf("#") + 1) : "";
      var tgt = hash && document.getElementById(hash);
      if (tgt) { tgt.scrollIntoView(); } else { window.scrollTo(0, 0); }
    }

    function navigate(url, push) {
      if (loading) return;
      loading = true;
      if (NP) NP.start();
      fetch(url, { headers: { "X-PJAX": "1" }, credentials: "same-origin" })
        .then(function (res) { if (!res.ok) throw new Error(res.status); return res.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var newMain = doc.querySelector("main");
          var curMain = document.querySelector("main");
          if (!newMain || !curMain) throw new Error("no main");

          document.title = doc.title;

          // drop duplicates of the persistent widgets, and let images load eagerly
          PERSIST_IDS.forEach(function (id) {
            var dup = newMain.querySelector("#" + id);
            if (dup) dup.parentNode.removeChild(dup);
          });
          var lazy = newMain.querySelectorAll("img[lazyload]");
          for (var i = 0; i < lazy.length; i++) lazy[i].removeAttribute("lazyload");

          // swap the page-title plate in the header
          var curIntro = document.querySelector(".page-intro");
          var newIntro = doc.querySelector(".page-intro");
          if (curIntro && newIntro) { curIntro.replaceWith(newIntro); }
          else if (curIntro && !newIntro) { curIntro.remove(); }
          else if (!curIntro && newIntro) {
            var hdr = document.querySelector("header");
            if (hdr) hdr.appendChild(newIntro);
          }

          curMain.replaceWith(newMain);

          if (push) history.pushState({ pjax: 1 }, "", url);
          afterSwap(url);
          if (NP) NP.done();
          loading = false;
        })
        .catch(function () {
          loading = false;
          if (NP) NP.done();
          window.location.href = url; // graceful fallback
        });
    }

    function eligible(a) {
      if (!a || !a.getAttribute) return false;
      if (a.target && a.target !== "_self") return false;
      if (a.hasAttribute("download") || a.getAttribute("rel") === "external") return false;
      var href = a.getAttribute("href");
      if (!href || href.charAt(0) === "#" || href.indexOf("javascript:") === 0) return false;
      if (a.origin !== location.origin) return false;
      if (/\.(zip|rar|7z|pdf|png|jpe?g|gif|webp|svg|flac|mp3|mp4|xml|json|txt)$/i.test(a.pathname)) return false;
      return true;
    }

    document.addEventListener("click", function (ev) {
      if (ev.defaultPrevented || ev.button !== 0 ||
          ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
      var a = ev.target.closest ? ev.target.closest("a") : null;
      if (!eligible(a)) return;
      ev.preventDefault();
      var url = a.href;
      if (url.split("#")[0] === location.href.split("#")[0]) {
        if (a.hash) {
          var tgt = document.getElementById(a.hash.slice(1));
          if (tgt) { history.pushState({ pjax: 1 }, "", url); tgt.scrollIntoView(); }
        }
        return;
      }
      navigate(url, true);
    });

    window.addEventListener("popstate", function () { navigate(location.href, false); });
    try { history.replaceState({ pjax: 1 }, "", location.href); } catch (e) { /* noop */ }
  }

  function init() {
    mountGlitterBg();
    mountGlitter();
    mountPlayer();
    mountPjax();
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
