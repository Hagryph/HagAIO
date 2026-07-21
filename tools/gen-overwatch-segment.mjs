import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SIZE = 128;
const SAMPLES = 8;
const EDGE_FEATHER = 0.05;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.join(root, "Media", "overwatch-segment-hq.tga");

// Preserve the reference fragment silhouette while supersampling its diagonal
// edges. The generated 32-bit TGA is deliberately deterministic and reviewable.
function alphaAt(pixelX, pixelY) {
    let coverage = 0;
    for (let sy = 0; sy < SAMPLES; sy += 1) {
        for (let sx = 0; sx < SAMPLES; sx += 1) {
            const x = (pixelX + (sx + 0.5) / SAMPLES) / SIZE;
            const y = (pixelY + (sy + 0.5) / SAMPLES) / SIZE;
            const left = 0.25 * (1 - y);
            const right = 1 - 0.25 * y;
            const edgeDistance = Math.min(x - left, right - x);
            const linear = Math.max(0, Math.min(1, edgeDistance / EDGE_FEATHER + 0.5));
            coverage += linear * linear * (3 - 2 * linear);
        }
    }
    return Math.round(255 * coverage / (SAMPLES * SAMPLES));
}

const header = Buffer.alloc(18);
header[2] = 2; // Uncompressed true-color image.
header.writeUInt16LE(SIZE, 12);
header.writeUInt16LE(SIZE, 14);
header[16] = 32;
header[17] = 0x28; // Eight alpha bits, top-left origin.

const pixels = Buffer.alloc(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
        const offset = (y * SIZE + x) * 4;
        pixels[offset] = 255;
        pixels[offset + 1] = 255;
        pixels[offset + 2] = 255;
        pixels[offset + 3] = alphaAt(x, y);
    }
}

fs.writeFileSync(output, Buffer.concat([header, pixels]));
console.log(`Generated ${path.relative(root, output)} (${SIZE}x${SIZE}, antialiased RGBA)`);
