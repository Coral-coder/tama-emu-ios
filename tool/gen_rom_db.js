const fs=require('fs');let s=fs.readFileSync(process.argv[2],'utf8');
s=s.replace('root.ParamixEmu = {','globalThis.__x={V1_ICONS,V1_NAMES,V1_ICONSEG,V1_CLOCK};root.ParamixEmu = {');
const vm=require('vm');const ctx={console,globalThis:{}};ctx.globalThis=ctx;ctx.window=undefined;vm.createContext(ctx);vm.runInContext(s,ctx);
const x=ctx.__x;let o='// Generated from Paramix Studio src/emu.js (GPL-3.0, mameise): ROM names (FNV-1a of the ROM bytes)\n// and the 16x16 menu icons drawn by mameise. Do not edit by hand; see tool/gen_rom_db.js.\n\n';
o+='const Map<int, String> kRomNames = {\n';for(const k in x.V1_NAMES)o+=`  0x${(+k>>>0).toString(16).toUpperCase().padStart(8,'0')}: '${x.V1_NAMES[k]}',\n`;o+='};\n\n';
o+='const List<String> kIconSegRoms = '+JSON.stringify(x.V1_ICONSEG).replace(/"/g,"'")+';\n';
o+='const List<String> kClockRoms = '+JSON.stringify(x.V1_CLOCK).replace(/"/g,"'")+';\n\n';
o+='/// 8 icons of 16 rows each; bit 15 is the left pixel. Icons 0-3 sit above the screen, 4-7 below.\nconst Map<String, List<List<int>>> kIconSets = {\n';
for(const k in x.V1_ICONS){o+=`  '${k}': [\n`;for(const ic of x.V1_ICONS[k])o+='    ['+ic.map(v=>'0x'+v.toString(16).padStart(4,'0')).join(', ')+'],\n';o+='  ],\n';}
o+='};\n';fs.writeFileSync(process.argv[3],o);console.log(Object.keys(x.V1_ICONS), Object.keys(x.V1_NAMES).length);
