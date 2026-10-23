const test = require("node:test");
const assert = require("node:assert/strict");
const { activeText, decode, parse, parseTimestamp } = require("../subtitle-parser.js");

test("parses SRT timestamps and multiline cues", () => {
  const cues = parse(`1\n00:00:01,250 --> 00:00:03,500\nHello\nworld\n\n2\n00:01:02,000 --> 00:01:04,000\nSecond`);
  assert.deepEqual(cues, [
    { start: 1.25, end: 3.5, text: "Hello\nworld" },
    { start: 62, end: 64, text: "Second" }
  ]);
});

test("parses WEBVTT metadata and strips formatting tags", () => {
  const cues = parse(`WEBVTT\n\nintro\n00:01.000 --> 00:02.500 position:50%\n<i>Hello</i> &amp; bye`);
  assert.deepEqual(cues, [{ start: 1, end: 2.5, text: "Hello & bye" }]);
});

test("ignores malformed and empty cues", () => {
  const cues = parse(`1\nnot a timestamp\nNope\n\n2\n00:00:02,000 --> 00:00:01,000\nBackwards`);
  assert.deepEqual(cues, []);
});

test("accepts hours and rejects out-of-range values", () => {
  assert.equal(parseTimestamp("01:02:03,400"), 3723.4);
  assert.equal(parseTimestamp("02:03.250"), 123.25);
  assert.equal(parseTimestamp("00:99:00.000"), null);
});

test("selects the active cue and applies track offset", () => {
  const cues = [
    { start: 1, end: 2, text: "First" },
    { start: 3, end: 5, text: "Second" }
  ];
  assert.equal(activeText(cues, 3.5), "Second");
  assert.equal(activeText(cues, 4.5, 1), "Second");
  assert.equal(activeText(cues, 2.5, 1), "First");
  assert.equal(activeText(cues, 9), "");
});

test("detects legacy Cyrillic and Western subtitle encodings", () => {
  const russian = decode(Uint8Array.from([0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2]));
  const german = decode(Uint8Array.from([0x54, 0xfc, 0x72]));
  assert.deepEqual(russian, { text: "Привет", encoding: "windows-1251" });
  assert.deepEqual(german, { text: "Tür", encoding: "windows-1252" });
});
