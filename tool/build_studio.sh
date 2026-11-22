#!/bin/sh
# Builds Paramix Studio from the submodule (third_party/paramix-studio) and puts it, with the app's
# bridge script inlined at the top of <head>, into assets/studio/index.html.
set -e
cd "$(dirname "$0")/.."
[ -f third_party/paramix-studio/build.js ] || git submodule update --init third_party/paramix-studio
(cd third_party/paramix-studio && node build.js)
node -e '
const fs = require("fs");
let h = fs.readFileSync("third_party/paramix-studio/dist/ParamixStudio.html", "utf8");
const b = fs.readFileSync("assets/studio/bridge.js", "utf8");
const i = h.indexOf("<head>");
if (i < 0) throw new Error("no <head> in the Studio");
h = h.slice(0, i + 6) + "\n<script>\n" + b + "\n</script>\n" + h.slice(i + 6);
fs.writeFileSync("assets/studio/index.html", h);
console.log("assets/studio/index.html", h.length, "bytes");
'
