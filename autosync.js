(function exposeAutoSync(globalObject) {
  function percentile(values, fraction) {
    if (!values.length) return 0;
    const sorted = [...values].sort((a, b) => a - b);
    const index = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * fraction)));
    return sorted[index];
  }

  function cueActive(cues, time) {
    let low = 0;
    let high = cues.length - 1;
    let candidate = -1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      if (Number(cues[middle].start) <= time) {
        candidate = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (candidate === -1) return 0;
    for (let index = candidate; index >= Math.max(0, candidate - 6); index -= 1) {
      if (Number(cues[index].end) >= time) return 1;
    }
    return 0;
  }

  function correlation(audioSignal, subtitleSignal) {
    let n11 = 0;
    let n10 = 0;
    let n01 = 0;
    let n00 = 0;
    for (let index = 0; index < audioSignal.length; index += 1) {
      if (audioSignal[index] && subtitleSignal[index]) n11 += 1;
      else if (audioSignal[index]) n10 += 1;
      else if (subtitleSignal[index]) n01 += 1;
      else n00 += 1;
    }
    const denominator = Math.sqrt((n11 + n10) * (n01 + n00) * (n11 + n01) * (n10 + n00));
    return denominator ? (n11 * n00 - n10 * n01) / denominator : -1;
  }

  function estimateOffset(samples, cues, options = {}) {
    const maxOffset = Number(options.maxOffset ?? 120);
    const qualityMaxOffset = Number(options.qualityMaxOffset ?? 30);
    const coarseStep = Number(options.step ?? 0.25);
    if (!Array.isArray(samples) || samples.length < 80 || !Array.isArray(cues) || cues.length < 2) {
      return { ok: false, reason: "Недостаточно данных для анализа" };
    }

    const energies = samples.map((sample) => Number(sample.energy)).filter(Number.isFinite);
    const spread = percentile(energies, 0.9) - percentile(energies, 0.1);
    if (!Number.isFinite(spread) || spread < 0.08) {
      return { ok: false, reason: "В аудио недостаточно изменений громкости" };
    }

    const approximateDuty = samples.reduce(
      (sum, sample) => sum + cueActive(cues, Number(sample.time)),
      0
    ) / samples.length;
    const targetDuty = Math.min(0.62, Math.max(0.22, approximateDuty || 0.4));
    const threshold = percentile(energies, 1 - targetDuty);
    const audioSignal = samples.map((sample) => Number(sample.energy) >= threshold ? 1 : 0);

    const scored = [];
    const scoreAt = (offset) => {
      const subtitleSignal = samples.map((sample) => cueActive(cues, Number(sample.time) - offset));
      const activeCount = subtitleSignal.reduce((sum, value) => sum + value, 0);
      if (activeCount < Math.max(8, samples.length * 0.05) || activeCount > samples.length * 0.9) return -1;
      return correlation(audioSignal, subtitleSignal);
    };

    for (let offset = -maxOffset; offset <= maxOffset + 0.0001; offset += coarseStep) {
      scored.push({ offset, score: scoreAt(offset) });
    }
    scored.sort((a, b) => b.score - a.score);
    const coarseBest = scored[0];

    let best = coarseBest;
    for (let offset = coarseBest.offset - coarseStep; offset <= coarseBest.offset + coarseStep; offset += 0.05) {
      const candidate = { offset, score: scoreAt(offset) };
      if (candidate.score > best.score) best = candidate;
    }

    const alternative = scored.find((item) => Math.abs(item.offset - best.offset) >= 2) || { score: -1 };
    const gap = best.score - alternative.score;
    const confidence = Math.max(0, Math.min(1, (best.score - 0.05) * 2.2 + Math.max(0, gap) * 1.5));
    if (Math.abs(best.offset) > qualityMaxOffset) {
      return {
        ok: false,
        reason: `Найден сомнительный сдвиг ${best.offset.toFixed(1)} с — результат не применён`,
        offset: best.offset,
        score: best.score,
        confidence
      };
    }
    if (best.score < 0.08 || confidence < 0.12) {
      return {
        ok: false,
        reason: "Не удалось уверенно сопоставить речь и реплики",
        score: best.score,
        confidence
      };
    }

    return {
      ok: true,
      offset: Math.round(best.offset * 20) / 20,
      score: best.score,
      confidence
    };
  }

  const api = { estimateOffset };
  globalObject.KinoxAutoSync = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis === "undefined" ? this : globalThis);
