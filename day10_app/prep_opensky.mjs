// Builds src/data.json from OpenSky monthly flight lists (observed flights) + OurAirports.
import fs from 'fs';
import zlib from 'zlib';
import readline from 'readline';
import * as d3 from 'd3';
import { feature } from 'topojson-client';
const dir = '../data/day10_opensky/';
const FILES = fs.readdirSync(dir).filter((f) => /^flightlist_.*\.csv\.gz$/.test(f)).sort();
const MIN_FLIGHTS = 8; // min observed flights (both directions) over the month to count as a route
const SCHEDULED = /^[A-Z]{3}\d{1,4}[A-Z]{0,2}$/; // airline-style callsign, e.g. QFA15. Drops private/GA/military.

// ICAO -> airport (only airports with an IATA code and scheduled service)
const apt = new Map();
for (const r of d3.csvParse(fs.readFileSync(dir + 'airports_ourairports.csv', 'utf8'))) {
  if (!r.iata_code || !/^(large|medium|small)_airport$/.test(r.type)) continue;
  apt.set(r.ident, r);
}
const counts = new Map();
let total = 0, kept = 0;
for (const f of FILES) {
  const rl = readline.createInterface({ input: fs.createReadStream(dir + f).pipe(zlib.createGunzip()) });
  let first = true;
  for await (const line of rl) {
    if (first) { first = false; continue; }
    total++;
    const c = line.split(',');
    const [callsign, , , , , o, d] = c;
    if (!o || !d || o === d || !SCHEDULED.test(callsign)) continue;
    if (!apt.has(o) || !apt.has(d)) continue;
    const key = o < d ? o + '|' + d : d + '|' + o;
    counts.set(key, (counts.get(key) || 0) + 1);
    kept++;
  }
  console.log(f, 'done');
}
const edges = [...counts].filter(([, n]) => n >= MIN_FLIGHTS).map(([k]) => k.split('|'));
const used = [...new Set(edges.flat())];
const names = new Intl.DisplayNames(['en'], { type: 'region' });
const world = JSON.parse(fs.readFileSync('node_modules/world-atlas/countries-110m.json', 'utf8'));
const feats = feature(world, world.objects.countries).features;
const list = used.map((icao) => {
  const r = apt.get(icao);
  return { iata: r.iata_code, name: r.name, city: r.municipality || r.name, country: names.of(r.iso_country), lat: +r.latitude_deg, lon: +r.longitude_deg };
});
const pos = new Map(used.map((u, i) => [u, i]));
const out = {
  airports: list.map((a) => {
    const f = feats.find((x) => d3.geoContains(x, [a.lon, a.lat]));
    return [a.iata, a.name, a.city, a.country, +a.lat.toFixed(3), +a.lon.toFixed(3), f ? +f.id : -1];
  }),
  routes: edges.map(([s, d]) => [pos.get(s), pos.get(d)]),
  meta: { files: FILES, minFlights: MIN_FLIGHTS, rows: total, kept },
};
fs.writeFileSync('src/data.json', JSON.stringify(out));
console.log(out.airports.length, 'airports', out.routes.length, 'routes', out.meta);
