(function () {
  var leaveTitle = "烸個亾洧着屬纡洎己哋杺凊";
  var returnTitle = "莈洧邇啲ㄖ孓，莪過啲並鈈恏";
  var originalTitle = document.title;
  var restoreTimer = null;

  function setTitle(text) {
    document.title = text;
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
    mountMusicToggle();
    document.addEventListener("visibilitychange", handleVisibilityChange);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
