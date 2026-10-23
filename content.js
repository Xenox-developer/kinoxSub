(async function startKinoxDualSubtitles() {
  if (globalThis.__kinoxDualSubtitlesInjected) return;
  globalThis.__kinoxDualSubtitlesInjected = true;

  const context = await sendMessage({ type: "KINOSUB_CONTEXT_CHECK" });
  if (!context?.allowed) return;

  const EMPTY_TRACK = { enabled: true, name: "", offset: 0, cues: [] };
  let state = {
    enabled: true,
    primary: { ...EMPTY_TRACK },
    secondary: { ...EMPTY_TRACK }
  };
  const videoTracks = new Map();
  let diagnostics = { frames: 0, videos: 0, visibleVideos: 0, overlayRenderers: 0, errors: [] };
  const localErrors = [];
  let autoSyncState = { status: "idle", requestId: "", progress: 0, message: "" };
  let autoSyncRunning = false;

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "KINOSUB_STATE") {
      state = normalizeState(message.state);
      applyStateToVideos();
      refreshPanel();
    }
    if (message?.type === "KINOSUB_DIAGNOSTICS") {
      diagnostics = message.diagnostics;
      refreshPanel();
    }
    if (message?.type === "KINOSUB_AUTOSYNC_START") {
      void startAutoSyncInFrame(message.requestId, message.duration);
    }
    if (message?.type === "KINOSUB_AUTOSYNC_EVENT" && window.top === window) {
      void handleAutoSyncEvent(message);
    }
  });

  const initial = await sendMessage({ type: "KINOSUB_GET_STATE" });
  if (initial?.ok) state = normalizeState(initial.state);

  scanVideos();
  const observer = new MutationObserver(scanVideos);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scanVideos, 1500);
  setInterval(renderOverlays, 100);
  setInterval(reportStatus, 3000);
  document.addEventListener("fullscreenchange", () => {
    applyStateToVideos();
    renderOverlays();
  });

  if (window.top === window && /(^|\.)kinox\.to$/i.test(location.hostname)) {
    createPanel();
  }

  function sendMessage(message) {
    return new Promise((resolve) => {
      chrome.runtime.sendMessage(message, (response) => {
        if (chrome.runtime.lastError) resolve(null);
        else resolve(response);
      });
    });
  }

  function normalizeTrack(track) {
    return {
      enabled: track?.enabled !== false,
      name: typeof track?.name === "string" ? track.name : "",
      offset: Number.isFinite(Number(track?.offset)) ? Number(track.offset) : 0,
      cues: Array.isArray(track?.cues) ? track.cues : []
    };
  }

  function normalizeState(value) {
    return {
      enabled: value?.enabled !== false,
      primary: normalizeTrack(value?.primary),
      secondary: normalizeTrack(value?.secondary)
    };
  }

  function findVideos(root, result = []) {
    if (!root?.querySelectorAll) return result;
    result.push(...root.querySelectorAll("video"));
    for (const element of root.querySelectorAll("*")) {
      if (element.shadowRoot) findVideos(element.shadowRoot, result);
    }
    return result;
  }

  function scanVideos() {
    for (const [video, tracks] of videoTracks) {
      if (!video.isConnected) {
        disableTracks(tracks);
        videoTracks.delete(video);
      }
    }

    for (const video of findVideos(document)) {
      if (!videoTracks.has(video)) {
        const overlay = createVideoOverlay();
        videoTracks.set(video, { primary: null, secondary: null, overlay });
        video.addEventListener("webkitbeginfullscreen", applyStateToVideos);
        video.addEventListener("webkitendfullscreen", applyStateToVideos);
        applyStateToVideo(video);
        console.info("[KinoSub] Видеоплеер найден", { url: location.href });
      }
    }
    reportStatus();
  }

  function applyStateToVideos() {
    scanVideos();
    for (const video of videoTracks.keys()) applyStateToVideo(video);
  }

  function disableTracks(tracks) {
    if (tracks.primary) tracks.primary.mode = "disabled";
    if (tracks.secondary) tracks.secondary.mode = "disabled";
    tracks.overlay?.remove();
  }

  function ensureTextTrack(video, slot) {
    const current = videoTracks.get(video);
    if (!current[slot]) {
      const label = slot === "primary" ? "KinoSub 1 · верхние" : "KinoSub 2 · нижние";
      current[slot] = video.addTextTrack("subtitles", label, slot === "primary" ? "mul" : "ru");
    }
    return current[slot];
  }

  function clearTextTrack(track) {
    if (!track?.cues) return;
    for (const cue of Array.from(track.cues)) track.removeCue(cue);
  }

  function applyStateToVideo(video) {
    applySlot(video, "primary", -3);
    applySlot(video, "secondary", -1);
  }

  function recordError(error, stage) {
    const message = `${stage}: ${error?.message || String(error)}`;
    if (!localErrors.includes(message)) localErrors.push(message);
    if (localErrors.length > 5) localErrors.shift();
    console.warn("[KinoSub]", message);
    reportStatus();
  }

  function applySlot(video, slot, line) {
    const data = state[slot];
    const current = videoTracks.get(video);

    if (!state.enabled || !data.enabled || data.cues.length === 0) {
      if (current[slot]) current[slot].mode = "disabled";
      return;
    }

    if (typeof VTTCue === "undefined") return;
    let track;
    try {
      track = ensureTextTrack(video, slot);
      track.mode = "disabled";
      clearTextTrack(track);
    } catch (error) {
      recordError(error, "native-track");
      return;
    }

    for (const item of data.cues) {
      const start = Math.max(0, Number(item.start) + data.offset);
      const end = Math.max(start + 0.05, Number(item.end) + data.offset);
      if (!Number.isFinite(start) || !Number.isFinite(end)) continue;

      try {
        const cue = new VTTCue(start, end, String(item.text));
        cue.line = line;
        cue.align = "center";
        cue.position = 50;
        cue.size = 96;
        track.addCue(cue);
      } catch (error) {
        recordError(error, "native-cue");
      }
    }

    track.mode = document.fullscreenElement === video ? "showing" : "disabled";
  }

  function createVideoOverlay() {
    const overlay = document.createElement("div");
    overlay.className = "kinosub-video-overlay";
    overlay.hidden = true;
    overlay.innerHTML = `
      <div class="kinosub-cue kinosub-cue-primary"></div>
      <div class="kinosub-cue kinosub-cue-secondary"></div>`;
    document.documentElement.appendChild(overlay);
    return overlay;
  }

  function isVisibleVideo(video) {
    const rect = video.getBoundingClientRect();
    const style = getComputedStyle(video);
    return rect.width >= 160 && rect.height >= 90 && style.display !== "none" && style.visibility !== "hidden";
  }

  function selectActiveVideo() {
    return [...videoTracks.keys()]
      .filter((video) => video.isConnected && isVisibleVideo(video) && !video.paused && !video.ended)
      .sort((a, b) => {
        const areaA = a.getBoundingClientRect().width * a.getBoundingClientRect().height;
        const areaB = b.getBoundingClientRect().width * b.getBoundingClientRect().height;
        return areaB - areaA;
      })[0] || null;
  }

  async function startAutoSyncInFrame(requestId, duration = 30) {
    if (autoSyncRunning) return;
    const video = selectActiveVideo();
    if (!video) return;
    autoSyncRunning = true;

    const emit = (event) => sendMessage({
      type: "KINOSUB_AUTOSYNC_EVENT",
      requestId,
      event
    });

    let audioContext;
    let capturedStream;
    try {
      const capture = video.captureStream || video.webkitCaptureStream;
      if (typeof capture !== "function") throw new Error("Этот плеер не поддерживает локальный захват аудио");
      capturedStream = capture.call(video);
      if (!capturedStream.getAudioTracks().length) throw new Error("Аудиодорожка плеера недоступна для анализа");

      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) throw new Error("Web Audio API недоступен");
      audioContext = new AudioContextClass();
      if (audioContext.state === "suspended") await audioContext.resume();

      const audioOnly = new MediaStream(capturedStream.getAudioTracks());
      const source = audioContext.createMediaStreamSource(audioOnly);
      const analyser = audioContext.createAnalyser();
      analyser.fftSize = 2048;
      analyser.smoothingTimeConstant = 0.15;
      source.connect(analyser);

      const frequencyData = new Float32Array(analyser.frequencyBinCount);
      const samples = [];
      const startedAt = performance.now();
      let lastProgress = -1;

      while ((performance.now() - startedAt) / 1000 < duration) {
        if (video.paused || video.ended) throw new Error("Видео остановлено — запустите его и повторите анализ");
        analyser.getFloatFrequencyData(frequencyData);
        const nyquist = audioContext.sampleRate / 2;
        let voicePower = 0;
        let bins = 0;
        for (let index = 0; index < frequencyData.length; index += 1) {
          const frequency = index * nyquist / frequencyData.length;
          if (frequency >= 120 && frequency <= 4000) {
            voicePower += Math.pow(10, frequencyData[index] / 10);
            bins += 1;
          }
        }
        samples.push({
          time: video.currentTime,
          energy: Math.log10(voicePower / Math.max(1, bins) + 1e-12) + 12
        });

        const progress = Math.min(100, Math.round(((performance.now() - startedAt) / 1000) / duration * 100));
        if (progress >= lastProgress + 3) {
          lastProgress = progress;
          void emit({ status: "progress", progress });
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }

      const results = {};
      for (const slot of ["primary", "secondary"]) {
        results[slot] = state[slot].cues.length
          ? KinoxAutoSync.estimateOffset(samples, state[slot].cues, {
              maxOffset: 60,
              qualityMaxOffset: 30,
              step: 0.25
            })
          : { ok: false, reason: "Дорожка не загружена" };
      }
      await emit({ status: "complete", progress: 100, results, samples: samples.length });
    } catch (error) {
      await emit({ status: "error", message: error?.message || String(error) });
    } finally {
      capturedStream?.getTracks().forEach((track) => track.stop());
      await audioContext?.close().catch(() => {});
      autoSyncRunning = false;
    }
  }

  async function handleAutoSyncEvent(message) {
    if (message.requestId !== autoSyncState.requestId) return;
    const event = message.event;
    if (event.status === "progress") {
      autoSyncState = { ...autoSyncState, status: "running", progress: event.progress };
      refreshPanel();
      return;
    }
    if (event.status === "error") {
      autoSyncState = { ...autoSyncState, status: "error", message: event.message };
      refreshPanel();
      return;
    }
    if (event.status !== "complete") return;

    const applied = [];
    for (const slot of ["primary", "secondary"]) {
      const result = event.results?.[slot];
      if (result?.ok && result.confidence >= 0.25 && Math.abs(result.offset) <= 30) {
        state[slot].offset = result.offset;
        applied.push(`${slot === "primary" ? "1" : "2"}: ${formatOffset(result.offset)}`);
      }
    }

    if (!applied.length) {
      const reason = event.results?.primary?.reason || event.results?.secondary?.reason || "Низкая уверенность";
      autoSyncState = { ...autoSyncState, status: "error", message: reason };
      refreshPanel();
      return;
    }

    autoSyncState = {
      ...autoSyncState,
      status: "complete",
      progress: 100,
      message: `Готово · ${applied.join(" · ")}`
    };
    await saveState();
  }

  function formatOffset(offset) {
    const value = Number(offset);
    return `${value > 0 ? "+" : ""}${value.toFixed(2).replace(".", ",")} с`;
  }

  function renderOverlays() {
    for (const [video, controller] of videoTracks) {
      const overlay = controller.overlay;
      if (!video.isConnected || !state.enabled || !isVisibleVideo(video)) {
        overlay.hidden = true;
        continue;
      }

      const fullscreenElement = document.fullscreenElement;
      if (fullscreenElement === video) {
        overlay.hidden = true;
        continue;
      }

      const desiredHost = fullscreenElement?.contains(video) ? fullscreenElement : document.documentElement;
      if (overlay.parentElement !== desiredHost) desiredHost.appendChild(overlay);

      const primary = state.primary.enabled
        ? KinoxSubtitleParser.activeText(state.primary.cues, video.currentTime, state.primary.offset)
        : "";
      const secondary = state.secondary.enabled
        ? KinoxSubtitleParser.activeText(state.secondary.cues, video.currentTime, state.secondary.offset)
        : "";

      if (!primary && !secondary) {
        overlay.hidden = true;
        continue;
      }

      const rect = video.getBoundingClientRect();
      overlay.style.left = `${rect.left}px`;
      overlay.style.top = `${rect.top}px`;
      overlay.style.width = `${rect.width}px`;
      overlay.style.height = `${rect.height}px`;
      overlay.querySelector(".kinosub-cue-primary").textContent = primary;
      overlay.querySelector(".kinosub-cue-secondary").textContent = secondary;
      overlay.hidden = false;
    }
  }

  function reportStatus() {
    let visibleVideos = 0;
    for (const video of videoTracks.keys()) {
      if (video.isConnected && isVisibleVideo(video)) visibleVideos += 1;
    }
    void sendMessage({
      type: "KINOSUB_REPORT",
      report: {
        videos: videoTracks.size,
        visibleVideos,
        overlayRenderers: [...videoTracks.values()].filter((item) => item.overlay?.isConnected).length,
        errors: localErrors
      }
    });
  }

  function createPanel() {
    if (document.getElementById("kinosub-root")) return;

    const root = document.createElement("div");
    root.id = "kinosub-root";
    root.innerHTML = `
      <button id="kinosub-launcher" type="button" title="Двойные субтитры">CC<sup>2</sup></button>
      <section id="kinosub-panel" hidden>
        <header>
          <strong>Двойные субтитры</strong>
          <button id="kinosub-close" type="button" aria-label="Закрыть">×</button>
        </header>
        <label class="kinosub-toggle">
          <input id="kinosub-enabled" type="checkbox">
          <span>Показывать субтитры</span>
        </label>
        <div id="kinosub-diagnostic" role="status"></div>
        <button id="kinosub-autosync" type="button">Автосинхронизация · 30 с</button>
        <button id="kinosub-reset-sync" type="button">Сбросить сдвиги</button>
        <div id="kinosub-autosync-status" role="status"></div>
        <div class="kinosub-track" data-slot="primary">
          <div class="kinosub-track-title"><b>1 · Верхняя дорожка</b><span class="kinosub-status"></span></div>
          <div class="kinosub-actions">
            <button class="kinosub-load" type="button">Загрузить SRT/VTT</button>
            <button class="kinosub-clear" type="button" title="Удалить дорожку">Очистить</button>
          </div>
          <div class="kinosub-sync">
            <span>Сдвиг</span>
            <button data-delta="-0.5" type="button">−0,5</button>
            <output>0,0 с</output>
            <button data-delta="0.5" type="button">+0,5</button>
          </div>
          <input class="kinosub-file" type="file" accept=".srt,.vtt,text/vtt,application/x-subrip" hidden>
        </div>
        <div class="kinosub-track" data-slot="secondary">
          <div class="kinosub-track-title"><b>2 · Нижняя дорожка</b><span class="kinosub-status"></span></div>
          <div class="kinosub-actions">
            <button class="kinosub-load" type="button">Загрузить SRT/VTT</button>
            <button class="kinosub-clear" type="button" title="Удалить дорожку">Очистить</button>
          </div>
          <div class="kinosub-sync">
            <span>Сдвиг</span>
            <button data-delta="-0.5" type="button">−0,5</button>
            <output>0,0 с</output>
            <button data-delta="0.5" type="button">+0,5</button>
          </div>
          <input class="kinosub-file" type="file" accept=".srt,.vtt,text/vtt,application/x-subrip" hidden>
        </div>
        <p class="kinosub-hint">Положительный сдвиг показывает текст позже.</p>
      </section>`;
    document.documentElement.appendChild(root);

    const panel = root.querySelector("#kinosub-panel");
    root.querySelector("#kinosub-launcher").addEventListener("click", () => {
      panel.hidden = !panel.hidden;
    });
    root.querySelector("#kinosub-close").addEventListener("click", () => {
      panel.hidden = true;
    });
    root.querySelector("#kinosub-enabled").addEventListener("change", async (event) => {
      state.enabled = event.target.checked;
      await saveState();
    });
    root.querySelector("#kinosub-autosync").addEventListener("click", async () => {
      if (!state.primary.cues.length && !state.secondary.cues.length) {
        autoSyncState = { status: "error", requestId: "", progress: 0, message: "Сначала загрузите SRT/VTT" };
        refreshPanel();
        return;
      }
      const requestId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
      autoSyncState = { status: "running", requestId, progress: 0, message: "" };
      refreshPanel();
      const response = await sendMessage({ type: "KINOSUB_AUTOSYNC_REQUEST", requestId, duration: 30 });
      if (!response?.ok) {
        autoSyncState = { ...autoSyncState, status: "error", message: "Не удалось запустить анализ" };
        refreshPanel();
      }
    });
    root.querySelector("#kinosub-reset-sync").addEventListener("click", async () => {
      state.primary.offset = 0;
      state.secondary.offset = 0;
      autoSyncState = { status: "idle", requestId: "", progress: 0, message: "Сдвиги сброшены" };
      await saveState();
    });

    for (const trackElement of root.querySelectorAll(".kinosub-track")) {
      const slot = trackElement.dataset.slot;
      const fileInput = trackElement.querySelector(".kinosub-file");

      trackElement.querySelector(".kinosub-load").addEventListener("click", () => fileInput.click());
      fileInput.addEventListener("change", async () => {
        const file = fileInput.files?.[0];
        if (!file) return;
        const decoded = KinoxSubtitleParser.decode(await file.arrayBuffer());
        const cues = KinoxSubtitleParser.parse(decoded.text);
        if (!cues.length) {
          alert("Не удалось найти реплики. Выберите корректный файл SRT или VTT.");
          fileInput.value = "";
          return;
        }
        state[slot] = { enabled: true, name: file.name, offset: 0, cues };
        console.info(`[KinoSub] ${file.name}: ${cues.length} реплик, ${decoded.encoding}`);
        fileInput.value = "";
        await saveState();
      });

      trackElement.querySelector(".kinosub-clear").addEventListener("click", async () => {
        state[slot] = { ...EMPTY_TRACK };
        await saveState();
      });

      for (const button of trackElement.querySelectorAll("[data-delta]")) {
        button.addEventListener("click", async () => {
          const next = state[slot].offset + Number(button.dataset.delta);
          state[slot].offset = Math.round(next * 10) / 10;
          await saveState();
        });
      }
    }

    refreshPanel();
  }

  async function saveState() {
    applyStateToVideos();
    refreshPanel();
    const response = await sendMessage({ type: "KINOSUB_SAVE_STATE", state });
    if (!response?.ok) console.warn("KinoSub: не удалось сохранить настройки.");
    renderOverlays();
  }

  function refreshPanel() {
    const root = document.getElementById("kinosub-root");
    if (!root) return;
    root.querySelector("#kinosub-enabled").checked = state.enabled;
    const autoSyncButton = root.querySelector("#kinosub-autosync");
    const autoSyncStatus = root.querySelector("#kinosub-autosync-status");
    autoSyncButton.disabled = autoSyncState.status === "running";
    autoSyncButton.textContent = autoSyncState.status === "running"
      ? `Анализирую звук… ${autoSyncState.progress}%`
      : "Автосинхронизация · 30 с";
    autoSyncStatus.dataset.level = autoSyncState.status;
    autoSyncStatus.textContent = autoSyncState.status === "running"
      ? "Не ставьте фильм на паузу"
      : autoSyncState.message;
    const diagnostic = root.querySelector("#kinosub-diagnostic");
    if (diagnostics.errors?.length) {
      diagnostic.dataset.level = "error";
      diagnostic.textContent = `Ошибка плеера: ${diagnostics.errors.at(-1)}`;
    } else if (diagnostics.visibleVideos > 0) {
      diagnostic.dataset.level = "ok";
      diagnostic.textContent = `Плеер найден · активных видео: ${diagnostics.visibleVideos}`;
    } else {
      diagnostic.dataset.level = "waiting";
      diagnostic.textContent = "Плеер не найден — запустите видео и пройдите проверку хостинга";
    }

    for (const slot of ["primary", "secondary"]) {
      const track = state[slot];
      const element = root.querySelector(`[data-slot="${slot}"]`);
      element.querySelector(".kinosub-status").textContent = track.cues.length
        ? `${track.name} · ${track.cues.length}`
        : "не загружена";
      element.querySelector("output").textContent = `${track.offset.toFixed(1).replace(".", ",")} с`;
      element.querySelector(".kinosub-clear").disabled = track.cues.length === 0;
    }
  }
})();
