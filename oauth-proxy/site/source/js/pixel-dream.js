(function () {
  var leaveTitle = "烸個亾洧着屬纡洎己哋杺凊";
  var returnTitle = "莈洧邇啲ㄖ孓，莪過啲並鈈恏";
  var originalTitle = document.title;
  var restoreTimer = null;

  function setTitle(text) {
    document.title = text;
  }

  function buildBackdrop() {
    if (document.querySelector(".pixel-backdrop")) {
      return;
    }

    var backdrop = document.createElement("div");
    backdrop.className = "pixel-backdrop";
    backdrop.setAttribute("aria-hidden", "true");
    document.body.prepend(backdrop);
  }

  function buildPixelFrame() {
    if (document.querySelector(".pixel-frame")) {
      return;
    }

    var frame = document.createElement("div");
    frame.className = "pixel-frame";
    frame.setAttribute("aria-hidden", "true");

    ["top", "right", "bottom", "left"].forEach(function (edge) {
      var edgeNode = document.createElement("span");
      edgeNode.className = "pixel-frame__edge pixel-frame__edge--" + edge;
      frame.appendChild(edgeNode);
    });

    [
      { position: "tl", label: "linplayer" },
      { position: "tr", label: "blingee" },
      { position: "bl", label: "pixel pop" },
      { position: "br", label: "wiki glow" }
    ].forEach(function (item) {
      var corner = document.createElement("span");
      corner.className = "pixel-frame__corner pixel-frame__corner--" + item.position;
      corner.textContent = item.label;
      frame.appendChild(corner);
    });

    [
      { x: "8%", y: "10%", size: "10px", duration: "3.4s", delay: "0s" },
      { x: "24%", y: "6%", size: "8px", duration: "3s", delay: "0.2s" },
      { x: "74%", y: "8%", size: "9px", duration: "3.3s", delay: "0.45s" },
      { x: "92%", y: "16%", size: "11px", duration: "3.7s", delay: "0.1s" },
      { x: "6%", y: "48%", size: "9px", duration: "3.1s", delay: "0.35s" },
      { x: "94%", y: "52%", size: "8px", duration: "3.25s", delay: "0.15s" },
      { x: "12%", y: "92%", size: "10px", duration: "3.5s", delay: "0.5s" },
      { x: "46%", y: "95%", size: "8px", duration: "3.2s", delay: "0.25s" },
      { x: "84%", y: "94%", size: "12px", duration: "3.8s", delay: "0.3s" }
    ].forEach(function (item) {
      var spark = document.createElement("span");
      spark.className = "pixel-frame__spark";
      spark.style.setProperty("--x", item.x);
      spark.style.setProperty("--y", item.y);
      spark.style.setProperty("--size", item.size);
      spark.style.setProperty("--duration", item.duration);
      spark.style.setProperty("--delay", item.delay);
      frame.appendChild(spark);
    });

    document.body.appendChild(frame);
  }

  function restoreOriginalTitle() {
    window.clearTimeout(restoreTimer);
    restoreTimer = window.setTimeout(function () {
      setTitle(originalTitle);
    }, 2400);
  }

  function handleVisibilityChange() {
    window.clearTimeout(restoreTimer);
    if (document.hidden) {
      setTitle(leaveTitle);
      return;
    }

    setTitle(returnTitle);
    restoreOriginalTitle();
  }

  function buildHeroBadge() {
    var bannerText = document.querySelector("#banner .banner-text");
    if (!bannerText || bannerText.querySelector(".pixel-hero-badge")) {
      return;
    }

    var badge = document.createElement("div");
    badge.className = "pixel-hero-badge";

    var icon = document.createElement("img");
    icon.src = "/img/linplayer-icon.png";
    icon.alt = "LinPlayer icon";

    var label = document.createElement("span");
    label.textContent = "blingee pixel archive";

    badge.appendChild(icon);
    badge.appendChild(label);
    bannerText.appendChild(badge);
  }

  function buildSparkles() {
    var banner = document.querySelector("#banner");
    if (!banner || banner.querySelector(".blingee-sparkles")) {
      return;
    }

    var sparkles = document.createElement("div");
    sparkles.className = "blingee-sparkles";

    [
      { x: "10%", y: "18%", size: "10px", duration: "2.8s", delay: "0s" },
      { x: "18%", y: "62%", size: "8px", duration: "3.1s", delay: "0.2s" },
      { x: "28%", y: "28%", size: "12px", duration: "3.4s", delay: "0.4s" },
      { x: "38%", y: "74%", size: "9px", duration: "2.9s", delay: "0.1s" },
      { x: "52%", y: "16%", size: "11px", duration: "3.6s", delay: "0.5s" },
      { x: "61%", y: "58%", size: "8px", duration: "3.1s", delay: "0.25s" },
      { x: "74%", y: "24%", size: "13px", duration: "3.8s", delay: "0.15s" },
      { x: "84%", y: "66%", size: "9px", duration: "3.2s", delay: "0.45s" },
      { x: "92%", y: "32%", size: "8px", duration: "2.7s", delay: "0.3s" }
    ].forEach(function (item) {
      var sparkle = document.createElement("span");
      sparkle.className = "blingee-sparkle";
      sparkle.style.setProperty("--x", item.x);
      sparkle.style.setProperty("--y", item.y);
      sparkle.style.setProperty("--size", item.size);
      sparkle.style.setProperty("--duration", item.duration);
      sparkle.style.setProperty("--delay", item.delay);
      sparkles.appendChild(sparkle);
    });

    banner.appendChild(sparkles);
  }

  function mountMusicToggle() {
    if (document.querySelector(".music-toggle")) {
      return;
    }

    var trackPath = "/assets/audio/Xploshi-NewYou.flac";
    var button = document.createElement("button");
    button.type = "button";
    button.className = "music-toggle";
    button.setAttribute("aria-label", "切换背景音乐");
    button.innerHTML =
      '<span class="music-toggle__icon" aria-hidden="true">&#9835;</span>' +
      '<span class="music-toggle__copy">' +
      '<strong>Now playing</strong>' +
      "<em>Xploshi - New You</em>" +
      "</span>" +
      '<span class="music-toggle__state">trying</span>';

    var audio = document.createElement("audio");
    audio.id = "pixel-dream-audio";
    audio.loop = true;
    audio.preload = "auto";
    audio.volume = 0.34;
    audio.style.display = "none";
    audio.src = trackPath;
    audio.setAttribute("aria-hidden", "true");

    var stateNode = button.querySelector(".music-toggle__state");
    var unlockEvents = ["pointerdown", "keydown", "touchstart"];

    function setState(state) {
      var labels = {
        trying: "trying",
        playing: "playing",
        paused: "paused",
        blocked: "click me",
        missing: "missing"
      };

      button.dataset.state = state;
      stateNode.textContent = labels[state] || state;
    }

    async function playAudio() {
      try {
        await audio.play();
        setState("playing");
        removeUnlockListeners();
        return true;
      } catch (error) {
        setState("blocked");
        return false;
      }
    }

    function pauseAudio() {
      audio.pause();
      setState("paused");
    }

    function handleUnlock() {
      if (audio.paused) {
        playAudio();
      }
    }

    function addUnlockListeners() {
      unlockEvents.forEach(function (eventName) {
        document.addEventListener(eventName, handleUnlock, { passive: true });
      });
    }

    function removeUnlockListeners() {
      unlockEvents.forEach(function (eventName) {
        document.removeEventListener(eventName, handleUnlock, { passive: true });
      });
    }

    audio.addEventListener("playing", function () {
      setState("playing");
    });

    audio.addEventListener("pause", function () {
      if (audio.currentTime > 0 && !audio.ended) {
        setState("paused");
      }
    });

    audio.addEventListener("error", function () {
      setState("missing");
    });

    button.addEventListener("click", function () {
      if (audio.paused) {
        playAudio();
        return;
      }

      pauseAudio();
    });

    document.body.appendChild(audio);
    document.body.appendChild(button);

    setState("trying");
    addUnlockListeners();
    playAudio();
  }

  function init() {
    buildBackdrop();
    buildPixelFrame();
    buildHeroBadge();
    buildSparkles();
    mountMusicToggle();
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
