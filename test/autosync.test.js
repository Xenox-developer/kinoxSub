const test = require("node:test");
const assert = require("node:assert/strict");
const { estimateOffset } = require("../autosync.js");

function buildSamples(cues, offset, duration = 80, step = 0.1) {
  const samples = [];
  for (let time = 0; time < duration; time += step) {
    const subtitleTime = time - offset;
    const speaking = cues.some((cue) => cue.start <= subtitleTime && cue.end >= subtitleTime);
    const deterministicNoise = ((Math.round(time * 10) * 17) % 13) / 100;
    samples.push({ time, energy: (speaking ? 1 : 0.12) + deterministicNoise });
  }
  return samples;
}

test("finds a positive subtitle delay from speech activity", () => {
  const cues = [
    { start: 5, end: 8 },
    { start: 12, end: 16 },
    { start: 22, end: 25 },
    { start: 31, end: 36 },
    { start: 44, end: 48 },
    { start: 57, end: 62 }
  ];
  const result = estimateOffset(buildSamples(cues, 4.5), cues, { maxOffset: 12, step: 0.25 });
  assert.equal(result.ok, true);
  assert.ok(Math.abs(result.offset - 4.5) <= 0.1, JSON.stringify(result));
});

test("rejects flat audio", () => {
  const samples = Array.from({ length: 300 }, (_, index) => ({ time: index / 10, energy: 0.5 }));
  const result = estimateOffset(samples, [{ start: 2, end: 5 }, { start: 8, end: 10 }]);
  assert.equal(result.ok, false);
});

test("rejects an implausibly large offset", () => {
  const cues = [
    { start: 2, end: 5 },
    { start: 9, end: 12 },
    { start: 17, end: 21 },
    { start: 28, end: 31 },
    { start: 38, end: 43 },
    { start: 50, end: 54 }
  ];
  const result = estimateOffset(buildSamples(cues, 42, 105), cues, {
    maxOffset: 60,
    qualityMaxOffset: 30,
    step: 0.25
  });
  assert.equal(result.ok, false);
  assert.match(result.reason, /сомнительный сдвиг/i);
});
