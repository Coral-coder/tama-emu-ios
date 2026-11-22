// Prints reference bytes from Paramix's flash.js (PDLO file, download chunks, PAU1 frame, COBS
// round trip, rescue block) for test/flash_ref_test.dart to compare the Dart port with.
const path = require('path'), fs = require('fs'), crypto = require('crypto');
globalThis.crypto = crypto.webcrypto;
const FL = require(path.join(__dirname, '../../third_party/paramix-studio/src/flash.js'));
const app = fs.readFileSync(path.join(__dirname, '../../third_party/paramix-studio/flash/flashapp.bin'));
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b)).digest('hex');
(async () => {
  const out = {};
  out.linkKey = Buffer.from(FL.linkKey, 'latin1').toString('hex');
  out.pdlo = sha(FL.buildPdlo(new Uint8Array(app)));
  const io = { write: async (d) => { io.last = d; }, onData: null };
  const link = new FL.Link(io); link.session = 0x12345678;
  out.frame = Buffer.from(link.frame(5, 7, 0xD49000, new Uint8Array([0, 4, 0, 0]))).toString('hex');
  const hdr = new Uint8Array(0x1000); hdr.set(Buffer.from('SONIXDEV')); for (let i = 8; i < 0x1000; i++) hdr[i] = (i * 7) & 255;
  out.rescue = sha(FL.rescueBlock(new Uint8Array(app.subarray(0, 0xE000)), hdr, null));
  const o = FL.sectorOrder(), ob = new Uint8Array(o.length * 4); o.forEach((v, i) => { ob[i * 4] = v & 255; ob[i * 4 + 1] = (v >> 8) & 255; ob[i * 4 + 2] = (v >> 16) & 255; ob[i * 4 + 3] = v >>> 24; }); out.order = sha(ob);
  console.log(JSON.stringify(out));
})();
