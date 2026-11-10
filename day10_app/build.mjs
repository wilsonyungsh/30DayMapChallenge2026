import { build } from 'esbuild';
import fs from 'fs';
const r = await build({
  entryPoints: ['src/App.jsx'], bundle: true, minify: true, write: false, outdir: 'out',
  loader: { '.json': 'json', '.jsx': 'jsx', '.css': 'css' }, define: { 'process.env.NODE_ENV': '"production"' },
});
const js = r.outputFiles.find((f) => f.path.endsWith('.js')).text.replace(/<\/script/g, '<\\/script');
const css = r.outputFiles.find((f) => f.path.endsWith('.css')).text;
fs.writeFileSync('../maps/day10_flights.html', `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Day 10 - Where is your one-stop vacation?</title><style>${css}</style></head><body><div id="root"></div><script>${js}</script></body></html>`);
console.log('built');
