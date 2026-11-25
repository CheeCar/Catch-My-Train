// Makes the app icon's smaller sizes from its master, icon_1024.png in the icon set: halves it step by step (each pixel is the
// average of the four it replaces, weighted by how opaque they are) and writes icon_<pixels>.png for the sizes asked for.
// Plain Node, no other tools: the files it writes carry nothing but the picture.
// Usage: node tools/icon/render.mjs <AppIcon.appiconset> 16 32 64 128 256 512
import fs from 'node:fs';
import zlib from 'node:zlib';

const outDir = process.argv[2];
const sizes = process.argv.slice(3).map(Number);
const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// An 8-bit RGBA PNG, not interlaced, as { size, pixels } (pixels: 4 bytes each, row by row)
function read(path) {
  const data = fs.readFileSync(path);
  if (!data.subarray(0, 8).equals(SIGNATURE)) throw new Error(`${path} is not a PNG file`);
  let header = null;
  const parts = [];
  for (let at = 8; at < data.length;) {
    const length = data.readUInt32BE(at), kind = data.toString('latin1', at + 4, at + 8);
    if (kind === 'IHDR') header = data.subarray(at + 8, at + 8 + length);
    if (kind === 'IDAT') parts.push(data.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const width = header.readUInt32BE(0), height = header.readUInt32BE(4);
  if (width !== height || header[8] !== 8 || header[9] !== 6 || header[12] !== 0) {
    throw new Error(`${path} must be a square 8-bit RGBA PNG, not interlaced`);
  }
  const raw = zlib.inflateSync(Buffer.concat(parts)), stride = width * 4;
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], row = y * (stride + 1) + 1, out = y * stride;
    for (let x = 0; x < stride; x++) {
      const left = x >= 4 ? pixels[out + x - 4] : 0, up = y > 0 ? pixels[out + x - stride] : 0;
      const corner = x >= 4 && y > 0 ? pixels[out + x - stride - 4] : 0;
      let add = 0;
      if (filter === 1) add = left;
      else if (filter === 2) add = up;
      else if (filter === 3) add = (left + up) >> 1;
      else if (filter === 4) {
        const p = left + up - corner, a = Math.abs(p - left), b = Math.abs(p - up), c = Math.abs(p - corner);
        add = a <= b && a <= c ? left : b <= c ? up : corner;
      } else if (filter !== 0) throw new Error(`${path}: unknown row filter ${filter}`);
      pixels[out + x] = (raw[row + x] + add) & 255;
    }
  }
  return { size: width, pixels: Float64Array.from(pixels) };
}

// Half the size: a pixel's opacity is the average of its four, its color their average weighted by opacity
function halve({ size, pixels }) {
  const half = size / 2, out = new Float64Array(half * half * 4);
  for (let y = 0; y < half; y++) {
    for (let x = 0; x < half; x++) {
      let alpha = 0;
      const color = [0, 0, 0];
      for (const [dx, dy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) {
        const from = ((2 * y + dy) * size + 2 * x + dx) * 4, a = pixels[from + 3];
        alpha += a;
        for (let c = 0; c < 3; c++) color[c] += pixels[from + c] * a;
      }
      const to = (y * half + x) * 4;
      for (let c = 0; c < 3; c++) out[to + c] = alpha > 0 ? color[c] / alpha : 0;
      out[to + 3] = alpha / 4;
    }
  }
  return { size: half, pixels: out };
}

function chunk(kind, body) {
  const head = Buffer.alloc(8), tail = Buffer.alloc(4), name = Buffer.from(kind, 'latin1');
  head.writeUInt32BE(body.length, 0);
  name.copy(head, 4);
  tail.writeUInt32BE(zlib.crc32 ? zlib.crc32(Buffer.concat([name, body])) : crc32(Buffer.concat([name, body])), 0);
  return Buffer.concat([head, body, tail]);
}

// For a Node without zlib.crc32
function crc32(data) {
  let crc = ~0;
  for (const byte of data) {
    crc ^= byte;
    for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return ~crc >>> 0;
}

function write(path, { size, pixels }) {
  const stride = size * 4, raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < stride; x++) raw[y * (stride + 1) + 1 + x] = Math.round(pixels[y * stride + x]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header.set([8, 6, 0, 0, 0], 8);
  fs.writeFileSync(path, Buffer.concat([SIGNATURE, chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))]));
}

let image = read(`${outDir}/icon_1024.png`);
if (image.size !== 1024) throw new Error('The master must be 1024 x 1024');
while (image.size > 16) {
  image = halve(image);
  if (sizes.includes(image.size)) write(`${outDir}/icon_${image.size}.png`, image);
}
