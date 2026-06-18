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

    var audio = document.createElement("audio");
    audio.id = "pixel-dream-audio";
    audio.loop = true;
    audio.preload = "auto";
    audio.volume = 0.34;
    audio.src = TRACK_PATH;
    audio.setAttribute("aria-hidden", "true");
    audio.style.display = "none";

    var btn = player.querySelector('[data-act="toggle"]');
    var stateNode = player.querySelector(".pixel-player__state");
    var volume = player.querySelector(".pixel-player__vol");
    var unlockEvents = ["pointerdown", "keydown", "touchstart"];

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

    function playAudio() {
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
    }

    function handleUnlock() {
      if (audio.paused && player.dataset.state !== "missing") {
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

    audio.addEventListener("playing", function () { setState("playing"); });
    audio.addEventListener("pause", function () {
      if (audio.currentTime > 0 && !audio.ended) {
        setState("paused");
      }
    });
    audio.addEventListener("error", function () { setState("missing"); });

    btn.addEventListener("click", function () {
      if (player.dataset.state === "missing") {
        return;
      }
      if (audio.paused) {
        playAudio();
      } else {
        pauseAudio();
      }
    });

    volume.addEventListener("input", function () {
      audio.volume = Math.min(1, Math.max(0, volume.value / 100));
      paintVolume();
    });

    document.body.appendChild(audio);
    document.body.appendChild(player);

    setState("loading");
    paintVolume();
    addUnlockListeners();
    playAudio();
  }

  function init() {
    mountGlitterBg();
    mountGlitter();
    mountPlayer();
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
