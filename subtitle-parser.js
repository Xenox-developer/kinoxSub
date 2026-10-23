(function exposeSubtitleParser(globalObject) {
  function parseTimestamp(value) {
    const normalized = String(value).trim().replace(",", ".");
    const parts = normalized.split(":");
    if (parts.length < 2 || parts.length > 3) return null;

    const seconds = Number(parts.pop());
    const minutes = Number(parts.pop());
    const hours = parts.length ? Number(parts.pop()) : 0;

    if (
      !Number.isFinite(hours) ||
      !Number.isFinite(minutes) ||
      !Number.isFinite(seconds) ||
      minutes < 0 ||
      minutes >= 60 ||
      seconds < 0 ||
      seconds >= 60 ||
      hours < 0
    ) {
      return null;
    }

    return hours * 3600 + minutes * 60 + seconds;
  }

  function decode(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      return { text: new TextDecoder("utf-8").decode(bytes.subarray(3)), encoding: "UTF-8" };
    }
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
      return { text: new TextDecoder("utf-16le").decode(bytes.subarray(2)), encoding: "UTF-16LE" };
    }
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
      return { text: new TextDecoder("utf-16be").decode(bytes.subarray(2)), encoding: "UTF-16BE" };
    }

    try {
      return { text: new TextDecoder("utf-8", { fatal: true }).decode(bytes), encoding: "UTF-8" };
    } catch {
      const highLetterBytes = bytes.reduce(
        (count, byte) => count + (byte >= 0xc0 && byte <= 0xff ? 1 : 0),
        0
      );
      const encoding = highLetterBytes >= 4 && highLetterBytes / Math.max(1, bytes.length) > 0.12
        ? "windows-1251"
        : "windows-1252";
      return { text: new TextDecoder(encoding).decode(bytes), encoding };
    }
  }

  function decodeEntities(value) {
    const entities = {
      amp: "&",
      apos: "'",
      gt: ">",
      lt: "<",
      nbsp: " ",
      quot: '"'
    };

    return value.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (match, entity) => {
      if (entity[0] === "#") {
        const hex = entity[1]?.toLowerCase() === "x";
        const codePoint = Number.parseInt(entity.slice(hex ? 2 : 1), hex ? 16 : 10);
        if (Number.isFinite(codePoint)) {
          try {
            return String.fromCodePoint(codePoint);
          } catch {
            return match;
          }
        }
      }
      return entities[entity.toLowerCase()] ?? match;
    });
  }

  function cleanCueText(lines) {
    return decodeEntities(
      lines
        .join("\n")
        .replace(/\{\\[^}]+\}/g, "")
        .replace(/<br\s*\/?>/gi, "\n")
        .replace(/<[^>]*>/g, "")
        .trim()
    );
  }

  function parse(text) {
    const normalized = String(text || "")
      .replace(/^\uFEFF/, "")
      .replace(/\r\n?/g, "\n")
      .trim();

    if (!normalized) return [];

    const blocks = normalized.split(/\n{2,}/);
    const cues = [];

    for (const block of blocks) {
      const lines = block.split("\n");
      const timingIndex = lines.findIndex((line) => line.includes("-->"));
      if (timingIndex === -1) continue;

      const timing = lines[timingIndex].match(
        /((?:\d{1,3}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d{1,3}:)?\d{1,2}:\d{2}[.,]\d{1,3})/
      );
      if (!timing) continue;

      const start = parseTimestamp(timing[1]);
      const end = parseTimestamp(timing[2]);
      const cueText = cleanCueText(lines.slice(timingIndex + 1));

      if (start === null || end === null || end <= start || !cueText) continue;
      cues.push({ start, end, text: cueText });
    }

    return cues.sort((a, b) => a.start - b.start || a.end - b.end);
  }

  function activeText(cues, currentTime, offset = 0) {
    if (!Array.isArray(cues) || cues.length === 0) return "";
    const time = Number(currentTime) - Number(offset || 0);
    if (!Number.isFinite(time)) return "";

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

    if (candidate === -1) return "";
    const active = [];
    for (let index = Math.max(0, candidate - 6); index <= candidate; index += 1) {
      const cue = cues[index];
      if (Number(cue.start) <= time && Number(cue.end) >= time) active.push(String(cue.text));
    }
    return active.join("\n");
  }

  const api = { activeText, decode, parse, parseTimestamp };
  globalObject.KinoxSubtitleParser = api;

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis === "undefined" ? this : globalThis);
