import React, { useMemo, useState, useRef, useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import * as d3 from 'd3';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { feature } from 'topojson-client';
import world from 'world-atlas/countries-110m.json';
import data from './data.json';
import './style.css';

const ORIGINS = [
  ['SYD', 'Sydney'], ['MEL', 'Melbourne'], ['BNE', 'Brisbane'], ['PER', 'Perth'],
  ['ADL', 'Adelaide'], ['CBR', 'Canberra'], ['HBA', 'Hobart'], ['DRW', 'Darwin'],
];
const NAME = Object.fromEntries(ORIGINS);
const A = data.airports.map(([iata, name, city, country, lat, lon, cid]) => ({ iata, name, city, country, lat, lon, cid }));
const IDX = new Map(A.map((a, i) => [a.iata, i]));
const adj = A.map(() => new Set());
data.routes.forEach(([s, d]) => { adj[s].add(d); adj[d].add(s); });
const countries = feature(world, world.objects.countries).features.filter((f) => f.id !== '010');

function reach(code) {
  const o = IDX.get(code);
  if (o === undefined) return { o, direct: new Set(), one: new Map() };
  const direct = new Set(adj[o]);
  const one = new Map(); // final destination -> transfer airports[]
  for (const v of direct) for (const d of adj[v]) {
    if (d === o || direct.has(d)) continue;
    if (!one.has(d)) one.set(d, []);
    one.get(d).push(v);
  }
  return { o, direct, one };
}
const REACH = Object.fromEntries(ORIGINS.map(([c]) => [c, reach(c)]));
const intl = (i) => A[i].country !== 'Australia';
// mode 0 = direct, 1 = direct + 1 stop, 2 = 1 stop only
function stats(r, mode) {
  const ids = [...(mode < 2 ? r.direct : []), ...(mode > 0 ? r.one.keys() : [])].filter(intl);
  return { airports: ids.length, countries: new Set(ids.map((i) => A[i].country)).size };
}
const STATS = Object.fromEntries(ORIGINS.map(([c]) => [c, [0, 1, 2].map((m) => stats(REACH[c], m))]));

// Great-circle arc as lon/lat points, unwrapped so it never jumps across the antimeridian.
const arcCache = new Map();
function arc(a, b) {
  const key = a * 10000 + b;
  if (!arcCache.has(key)) {
    const f = d3.geoInterpolate([A[a].lon, A[a].lat], [A[b].lon, A[b].lat]);
    const pts = [];
    for (let t = 0; t <= 20; t++) {
      const p = f(t / 20);
      if (pts.length) { const prev = pts[pts.length - 1][0]; while (p[0] - prev > 180) p[0] -= 360; while (p[0] - prev < -180) p[0] += 360; }
      pts.push(p);
    }
    arcCache.set(key, pts);
  }
  return arcCache.get(key);
}
const line = (a, b, props = {}) => ({ type: 'Feature', properties: props, geometry: { type: 'LineString', coordinates: arc(a, b) } });
const fc = (features) => ({ type: 'FeatureCollection', features });
const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();

const RAD = Math.PI / 180;
function bearing([lo1, la1], [lo2, la2]) {
  const dl = (lo2 - lo1) * RAD, p1 = la1 * RAD, p2 = la2 * RAD;
  return (Math.atan2(Math.sin(dl) * Math.cos(p2), Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)) / RAD + 360) % 360;
}
// Top-down airliner icon (four engines, long swept wings), nose pointing up.
function a380Icon() {
  const S = 96, c = document.createElement('canvas');
  c.width = c.height = S;
  const x = c.getContext('2d');
  x.lineJoin = 'round'; x.lineWidth = 2.5; x.strokeStyle = '#10243a'; x.fillStyle = '#ffffff';
  const half = (pts) => { x.beginPath(); pts.forEach(([a, b], i) => (i ? x.lineTo(a, b) : x.moveTo(a, b))); [...pts].reverse().forEach(([a, b]) => x.lineTo(S - a, b)); x.closePath(); x.fill(); x.stroke(); };
  half([[48, 78], [40, 90], [40, 93], [48, 91]]); // tailplane (mirrored)
  half([[48, 80], [34, 86], [34, 90], [48, 88]]);
  x.beginPath(); x.moveTo(48, 4); x.bezierCurveTo(55, 4, 56, 14, 56, 28); x.lineTo(56, 78); x.bezierCurveTo(56, 88, 52, 92, 48, 92); x.bezierCurveTo(44, 92, 40, 88, 40, 78); x.lineTo(40, 28); x.bezierCurveTo(40, 14, 41, 4, 48, 4); x.closePath(); x.fill(); x.stroke();
  half([[56, 36], [92, 62], [92, 68], [56, 58]]); // main wings
  x.fillStyle = '#10243a';
  [[28, 55], [16, 61]].forEach(([a, b]) => { [a, S - a].forEach((cx) => { x.beginPath(); x.ellipse(cx, b, 2.6, 5, 0, 0, 7); x.fill(); }); });
  return x.getImageData(0, 0, S, S);
}

function App() {
  const [origin, setOrigin] = useState('BNE');
  const [steps, setSteps] = useState(0);
  const [pin, setPin] = useState(null);
  const [tip, setTip] = useState(null);
  const [ready, setReady] = useState(false);
  const [viaSel, setViaSel] = useState(null);
  const [fly, setFly] = useState(null);
  const [basemap, setBasemap] = useState('map');
  const [view, setView] = useState('follow');
  const viewRef = useRef('follow');
  const anim = useRef({}), hoverId = useRef(null);
  const box = useRef(), map = useRef(), marker = useRef();

  useEffect(() => setPin(null), [origin, steps]);
  useEffect(() => {
    stopFly();
    const vs = pin !== null ? REACH[origin].one.get(pin) : null;
    if (!vs) return setViaSel(null);
    const sc = (v) => d3.geoDistance([o0.lon, o0.lat], [A[v].lon, A[v].lat]) + d3.geoDistance([A[v].lon, A[v].lat], [A[pin].lon, A[pin].lat]);
    setViaSel([...vs].sort((a, b) => sc(a) - sc(b))[0]);
  }, [pin, origin]);

  const r = REACH[origin];
  const o0 = A[r.o];
  const st = STATS[origin];
  const showD = steps < 2, showO = steps > 0;
  const o = A[r.o];
  const pinVia = pin !== null ? r.one.get(pin) : null;
  const list = useMemo(() => {
    const m = new Map();
    const add = (i, kind) => {
      if (!intl(i)) return;
      const c = A[i].country;
      if (!m.has(c)) m.set(c, { c, d: 0, o: 0 });
      m.get(c)[kind]++;
    };
    if (showD) r.direct.forEach((i) => add(i, 'd'));
    if (showO) r.one.forEach((_, i) => add(i, 'o'));
    return [...m.values()].sort((a, b) => (b.d > 0) - (a.d > 0) || b.d - a.d || b.o - a.o || a.c.localeCompare(b.c));
  }, [r, steps]);
  const max = Math.max(...ORIGINS.map(([c]) => STATS[c][steps].countries));

  // create the globe once
  useEffect(() => {
    const sea = css('--sea');
    const m = new maplibregl.Map({
      container: box.current,
      style: { version: 8, projection: { type: 'globe' }, sources: {}, layers: [{ id: 'bg', type: 'background', paint: { 'background-color': sea } }] },
      center: [REACH.BNE && A[REACH.BNE.o].lon - 25, 5], zoom: 1.9, minZoom: 0.8, maxZoom: 12, maxPitch: 85,
      attributionControl: { compact: true, customAttribution: 'Flights: OpenSky Network · Airports: OurAirports · Borders: Natural Earth' },
    });
    map.current = m;
    m.on('load', () => {
      const src = (id) => m.addSource(id, { type: 'geojson', data: fc([]) });
      ['countries', 'legs1', 'legs2', 'pin', 'plane'].forEach(src);
      m.addSource('dots', { type: 'geojson', data: fc([]), promoteId: 'i' });
      m.addImage('a380', a380Icon(), { pixelRatio: 2 });
      m.addSource('esri', { type: 'raster', tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'], tileSize: 256, maxzoom: 17, attribution: 'Imagery © Esri, Maxar, Earthstar Geographics' });
      m.addLayer({ id: 'sat', type: 'raster', source: 'esri', layout: { visibility: 'none' } });
      m.addLayer({ id: 'countries', type: 'fill', source: 'countries', paint: { 'fill-color': ['match', ['get', 'cls'], 'd', css('--dl'), 'o', css('--ol'), css('--land')] } });
      m.addLayer({ id: 'borders', type: 'line', source: 'countries', paint: { 'line-color': css('--panel'), 'line-width': 0.5 } });
      m.addLayer({ id: 'legs1', type: 'line', source: 'legs1', paint: { 'line-color': css('--d'), 'line-width': 0.8, 'line-opacity': ['case', ['get', 'dim'], 0.08, 0.45] } });
      m.addLayer({ id: 'legs2', type: 'line', source: 'legs2', paint: { 'line-color': css('--o'), 'line-width': 0.7, 'line-opacity': ['case', ['get', 'dim'], 0.04, 0.3] } });
      m.addLayer({ id: 'pin', type: 'line', source: 'pin', paint: { 'line-color': ['match', ['get', 'k'], 'a', css('--d'), css('--o')], 'line-width': ['case', ['get', 'sel'], 3.4, 1.3], 'line-opacity': ['case', ['get', 'sel'], 1, 0.6] } });
      const HOV = ['boolean', ['feature-state', 'hover'], false];
      m.addLayer({ id: 'glow', type: 'circle', source: 'dots', paint: {
        'circle-color': ['match', ['get', 'k'], 'd', css('--d'), css('--o')],
        'circle-radius': ['case', HOV, 22, ['get', 'pin'], 18, 0], 'circle-blur': 0.9, 'circle-opacity': 0.6 } });
      m.addLayer({ id: 'dots', type: 'circle', source: 'dots', paint: {
        'circle-color': ['match', ['get', 'k'], 'd', css('--d'), css('--o')],
        'circle-radius': ['case', HOV, 11, ['get', 'pin'], 10, ['match', ['get', 'k'], 'd', 7, 6]],
        'circle-stroke-color': ['case', HOV, '#ffffff', css('--panel')], 'circle-stroke-width': ['case', HOV, 2.5, 1.2], 'circle-opacity': 0.95 } });
      m.addLayer({ id: 'plane', type: 'symbol', source: 'plane', layout: {
        'icon-image': 'a380', 'icon-size': 0.9, 'icon-rotate': ['get', 'h'], 'icon-rotation-alignment': 'map', 'icon-pitch-alignment': 'map',
        'icon-allow-overlap': true, 'icon-ignore-placement': true } });
      const hover = (e) => {
        const f = e.features[0];
        if (hoverId.current !== f.properties.i) {
          if (hoverId.current !== null) m.setFeatureState({ source: 'dots', id: hoverId.current }, { hover: false });
          hoverId.current = f.properties.i;
          m.setFeatureState({ source: 'dots', id: hoverId.current }, { hover: true });
        }
        setTip({ i: +f.properties.i, kind: f.properties.k, x: e.originalEvent.clientX, y: e.originalEvent.clientY });
        m.getCanvas().style.cursor = 'pointer';
      };
      m.on('mousemove', 'dots', hover);
      m.on('mouseleave', 'dots', () => { if (hoverId.current !== null) m.setFeatureState({ source: 'dots', id: hoverId.current }, { hover: false }); hoverId.current = null; setTip(null); m.getCanvas().style.cursor = ''; });
      m.on('click', 'dots', (e) => { const i = +e.features[0].properties.i; setPin((p) => (p === i ? null : i)); });
      const el = document.createElement('div');
      el.className = 'omark';
      marker.current = new maplibregl.Marker({ element: el }).setLngLat([0, 0]).addTo(m);
      setReady(true);
    });
    return () => m.remove();
  }, []);

  // map / satellite basemap
  useEffect(() => {
    if (!ready) return;
    const m = map.current, sat = basemap === 'sat';
    m.setLayoutProperty('sat', 'visibility', sat ? 'visible' : 'none');
    m.setPaintProperty('countries', 'fill-opacity', ['match', ['get', 'cls'], 'n', sat ? 0 : 1, sat ? 0.3 : 1]);
    m.setPaintProperty('borders', 'line-color', sat ? 'rgba(255,255,255,0.45)' : css('--panel'));
    m.setPaintProperty('legs1', 'line-color', sat ? '#7cc4ff' : css('--d'));
    m.setPaintProperty('legs2', 'line-color', sat ? '#ffc24d' : css('--o'));
  }, [ready, basemap]);

  // follow / cockpit camera
  const flying = fly !== null;
  useEffect(() => {
    viewRef.current = view;
    if (!ready) return;
    const m = map.current, cock = view === 'cockpit' && flying;
    m.setLayoutProperty('plane', 'visibility', cock ? 'none' : 'visible');
    const l = anim.current.last;
    if (flying && l) m.jumpTo(cock ? { center: l.p, bearing: l.h, pitch: 76, zoom: 5.4 } : { center: l.p, bearing: 0, pitch: 0, zoom: 3.4 });
  }, [ready, view, flying]);

  // refresh map data whenever the selection changes
  useEffect(() => {
    if (!ready) return;
    const m = map.current;
    const dIds = new Set(showD ? [...r.direct].filter(intl).map((i) => A[i].cid) : []);
    const oIds = new Set(showO ? [...r.one.keys()].filter(intl).map((i) => A[i].cid) : []);
    m.getSource('countries').setData(fc(countries.map((f) => ({ ...f, properties: { cls: dIds.has(+f.id) ? 'd' : oIds.has(+f.id) ? 'o' : 'n' } }))));
    const dim = pin !== null;
    // departure -> transfer / direct destination
    m.getSource('legs1').setData(fc([...r.direct].map((i) => line(r.o, i, { dim: dim || steps === 2 }))));
    // transfer -> final destination (never departure -> final destination)
    const l2 = [];
    if (showO) {
      const seen = new Set();
      r.one.forEach((vias, d) => vias.forEach((v) => { const k = v * 10000 + d; if (!seen.has(k)) { seen.add(k); l2.push(line(v, d, { dim })); } }));
    }
    m.getSource('legs2').setData(fc(l2));
    const pl = [];
    if (pin !== null) {
      if (r.direct.has(pin)) pl.push(line(r.o, pin, { k: 'a', sel: true }));
      else if (pinVia) pinVia.forEach((v) => { pl.push(line(r.o, v, { k: 'a', sel: v === viaSel })); pl.push(line(v, pin, { k: 'b', sel: v === viaSel })); });
    }
    m.getSource('pin').setData(fc(pl));
    const dots = [];
    if (showD) r.direct.forEach((i) => dots.push({ type: 'Feature', properties: { i, k: 'd', pin: i === pin }, geometry: { type: 'Point', coordinates: [A[i].lon, A[i].lat] } }));
    if (showO) r.one.forEach((_, i) => dots.push({ type: 'Feature', properties: { i, k: 'o', pin: i === pin }, geometry: { type: 'Point', coordinates: [A[i].lon, A[i].lat] } }));
    m.getSource('dots').setData(fc(dots));
  }, [ready, origin, steps, pin, viaSel]);

  useEffect(() => {
    if (!ready) return;
    marker.current.setLngLat([o.lon, o.lat]);
    marker.current.getElement().textContent = o.city;
    map.current.easeTo({ center: [o.lon - 25, 5], zoom: 1.9, duration: 1200 });
  }, [ready, origin]);

  function stopFly(reset) {
    cancelAnimationFrame(anim.current.raf);
    anim.current.raf = 0;
    const m = map.current;
    if (m && m.getSource('plane')) m.getSource('plane').setData(fc([]));
    if (m && anim.current.active) m.easeTo({ pitch: 0, bearing: 0, ...(reset ? { center: [o0.lon - 25, 5], zoom: 1.9 } : {}), duration: 1000 });
    anim.current.active = false;
    setFly(null);
  }
  function startFly() {
    const m = map.current;
    stopFly();
    const dest = pin;
    const direct = r.direct.has(dest);
    const legs = direct ? [[r.o, dest]] : [[r.o, viaSel], [viaSel, dest]];
    const ll = (i) => [A[i].lon, A[i].lat];
    const interp = legs.map(([a, b]) => d3.geoInterpolate(ll(a), ll(b)));
    const rads = legs.map(([a, b]) => d3.geoDistance(ll(a), ll(b)));
    const total = rads.reduce((x, y) => x + y, 0);
    const T = Math.min(24000, Math.max(6000, total * 5000)), DWELL = 1800;
    const tl = []; let t = 0;
    legs.forEach((_, i) => {
      tl.push({ t0: t, t1: t + (T * rads[i]) / total, i }); t = tl[tl.length - 1].t1;
      if (i < legs.length - 1) { tl.push({ t0: t, t1: t + DWELL, i, dwell: true }); t += DWELL; }
    });
    const at = (i, f) => {
      const g = Math.min(Math.max(f, 0), 1), p = interp[i](g);
      const h = g > 0.98 ? bearing(interp[i](0.97), p) : bearing(p, interp[i](g + 0.02));
      return { p, h };
    };
    const put = ({ p, h }) => {
      m.getSource('plane').setData(fc([{ type: 'Feature', properties: { h }, geometry: { type: 'Point', coordinates: p } }]));
      anim.current.last = { p, h };
      m.jumpTo(viewRef.current === 'cockpit' ? { center: p, bearing: h, pitch: 76, zoom: 5.4 } : { center: p });
    };
    const city = (i) => `${A[i].city} (${A[i].iata})`;
    anim.current.active = true; setTip(null);
    const h0 = at(0, 0).h, cock0 = viewRef.current === 'cockpit';
    m.setLayoutProperty('plane', 'visibility', cock0 ? 'none' : 'visible');
    m.easeTo(cock0 ? { center: ll(r.o), zoom: 5.4, pitch: 76, bearing: h0, duration: 1000 } : { center: ll(r.o), zoom: 3.4, duration: 1000 });
    { const { p, h } = at(0, 0); m.getSource('plane').setData(fc([{ type: 'Feature', properties: { h }, geometry: { type: 'Point', coordinates: p } }])); }
    setFly({ prog: 0, text: `Boarding at ${city(r.o)}` });
    const start = performance.now() + 1100;
    let last = -1;
    const tick = (now) => {
      const e = now - start;
      if (e >= 0) {
        const seg = tl.find((s) => e >= s.t0 && e < s.t1);
        if (!seg) {
          put(at(legs.length - 1, 1));
          setFly({ prog: 1, done: true, h: anim.current.last.h, text: `Landed in ${city(dest)}` });
          return;
        }
        const f = seg.dwell ? 1 : (e - seg.t0) / (seg.t1 - seg.t0);
        put(at(seg.i, f));
        const prog = Math.round((e / t) * 100);
        if (prog !== last) {
          last = prog;
          setFly({ prog: prog / 100, h: anim.current.last.h, text: seg.dwell ? `Transfer in ${city(viaSel)}` : `Flying to ${city(legs[seg.i][1])}` });
        }
      }
      anim.current.raf = requestAnimationFrame(tick);
    };
    anim.current.raf = requestAnimationFrame(tick);
  }

  return (
    <div className="app">
      <aside>
        <h1>Where is your one-stop vacation?</h1>
        <div className="year">Flight data: October 2022</div>
        <p className="sub">Real airline routes from {NAME[origin]} ({origin}): direct, or with one stop.</p>

        <div className="group"><label>Departure city</label>
          <div className="seg wrap">{ORIGINS.map(([c, n]) => <button key={c} className={origin === c ? 'on' : ''} onClick={() => setOrigin(c)}>{n}</button>)}</div></div>
        <div className="group"><label>Stops</label>
          <div className="seg">
            <button className={steps === 0 ? 'on' : ''} onClick={() => setSteps(0)}>Direct only</button>
            <button className={steps === 1 ? 'on' : ''} onClick={() => setSteps(1)}>Up to 1 stop</button>
            <button className={steps === 2 ? 'on' : ''} onClick={() => setSteps(2)}>1 stop only</button></div></div>

        <div className="hero">
          <div className="big"><b>{st[steps].countries}</b><span>countries</span></div>
          <div className="big"><b>{st[steps].airports}</b><span>airports</span></div>
        </div>
        <p className="line">From {NAME[origin]} you can reach <b>{st[0].countries} countries</b> ({st[0].airports} airports) directly
          {steps > 0 && <>, and <b>{st[2].countries} countries</b> ({st[2].airports} airports) that need exactly one stop{steps === 1 && <> ({st[1].countries} countries in total)</>}</>}. Australia itself is not counted.</p>

        <h2>Compare capital cities <small>{['direct', 'up to 1 stop', '1 stop only'][steps]}, countries</small></h2>
        <ul className="bars">{ORIGINS.map(([c, n]) => (
          <li key={c} className={c === origin ? 'sel' : ''} onClick={() => setOrigin(c)}>
            <span className="n">{n}</span>
            <span className="track"><i style={{ width: `${(STATS[c][steps].countries / max) * 100}%` }} /></span>
            <span className="v">{STATS[c][steps].countries}</span>
          </li>))}</ul>

        <h2>Countries reachable from {NAME[origin]}</h2>
        <div className="chips">{list.map((x) => (
          <span key={x.c} className={x.d ? 'chip d' : 'chip o'}>{x.c}<em>{x.d ? x.d : ''}</em></span>))}</div>

        <div className="note">
          <h2>Data source &amp; limitations</h2>
          <ul>
            <li><b>Source:</b> <a href="https://zenodo.org/records/7923702" target="_blank" rel="noreferrer">OpenSky Network</a> observed flights (ADS-B), October 2022, the newest free bulk release. Airports from <a href="https://ourairports.com/data/" target="_blank" rel="noreferrer">OurAirports</a>. Borders: Natural Earth via world-atlas.</li>
            <li><b>Observed, not scheduled:</b> a route is any airport pair with at least {data.meta.minFlights} airline-style flights in the month. Private, military and unidentified flights are dropped. Origin and destination are inferred from each flight's track, so a few wrong or missing pairs are expected.</li>
            <li><b>Not today's timetable:</b> the data is one month, October 2022, still during the post-COVID recovery (Darwin, Canberra and Hobart had no international flights then). Routes added since (and routes that have stopped) are not reflected, and the counts are likely lower than today's.</li>
            <li><b>Coverage gaps:</b> ADS-B receivers are volunteer-run, so flights over oceans, Africa and parts of Asia are caught less often, and some real routes fall below the threshold.</li>
            <li><b>Globe:</b> lines are great-circle arcs drawn on a MapLibre globe, so they show shape, not actual flight paths.</li>
            <li><b>Return flights assumed:</b> a route A to B is treated as also B to A.</li>
            <li><b>One stop means one connection:</b> "1 stop only" lists airports with no direct flight but a one-connection route.  any two routes sharing an airport. Layover time, separate tickets, visas and baggage transfers are ignored, and domestic hubs (e.g. via Sydney) count as stops.</li>
<li><b>Countries</b> follow the airport's ISO country code (OurAirports)' so territories (e.g. Guam, Réunion) count as separate countries.</li>
          </ul>
        </div>
      </aside>

      <main>
        <div ref={box} className="map" />
        <div className="seg basemap">
          <button className={basemap === 'map' ? 'on' : ''} onClick={() => setBasemap('map')}>Map</button>
          <button className={basemap === 'sat' ? 'on' : ''} onClick={() => setBasemap('sat')}>Satellite</button></div>
        {flying && view === 'cockpit' && (
          <div className="cockpit"><i className="pl" /><i className="pr" /><i className="dash" />
            <div className="hud"><b>HDG {String(Math.round(fly.h ?? 0)).padStart(3, '0')}°</b><span>{fly.text}</span></div></div>)}
        <div className="badge">Routes observed October 2022</div>
        <div className="legend">
          {showD && <span><i className="sw d" /> Direct destination</span>}
          {showO && <span><i className="sw o" /> Final destination after 1 stop (line = transfer to destination)</span>}
          <span><i className="sw og" /> {NAME[origin]}</span>
          <span className="hint">Drag to rotate, scroll to zoom, click a dot for the route</span>
        </div>
        {pin !== null && (
          <div className="pinbox">
            <div><b>{A[pin].city}, {A[pin].country}</b> ({A[pin].iata}) {r.direct.has(pin) ? 'is direct.' : <>needs one stop{pinVia.length > 1 ? ` (${pinVia.length} transfer options)` : ''}.</>}</div>
            <div className="flyrow">
              {pinVia && pinVia.length > 1 && !fly && (
                <label className="via">Transfer at <select value={viaSel ?? ''} onChange={(e) => setViaSel(+e.target.value)}>
                  {pinVia.map((v) => <option key={v} value={v}>{A[v].city} ({A[v].iata})</option>)}</select></label>)}
              {pinVia && pinVia.length === 1 && <span className="via">Transfer at {A[pinVia[0]].city} ({A[pinVia[0]].iata})</span>}
              <span className="seg mini">
                <button className={view === 'follow' ? 'on' : ''} onClick={() => setView('follow')}>Follow</button>
                <button className={view === 'cockpit' ? 'on' : ''} onClick={() => setView('cockpit')}>Cockpit</button></span>
              {!fly && <button className="fly" onClick={startFly}>✈ Fly this route</button>}
              {fly && <><span className="via">{fly.text}</span><progress value={fly.prog} max="1" />
                <button className="fly" onClick={startFly}>{fly.done ? 'Replay' : 'Restart'}</button>
                <button className="fly ghost" onClick={() => stopFly(true)}>Stop</button></>}
            </div>
            <button className="x" onClick={() => setPin(null)}>×</button></div>)}
        {tip && (
          <div className="tip" style={{ left: tip.x + 12, top: tip.y + 12 }}>
            <b>{A[tip.i].city}, {A[tip.i].country}</b>
            <div>{A[tip.i].name} ({A[tip.i].iata})</div>
            <div>{tip.kind === 'd' ? 'Direct from ' + NAME[origin] : 'Via ' + r.one.get(tip.i).slice(0, 4).map((v) => A[v].iata).join(', ') + (r.one.get(tip.i).length > 4 ? ` +${r.one.get(tip.i).length - 4}` : '')}</div>
          </div>)}
      </main>
    </div>
  );
}
createRoot(document.getElementById('root')).render(<App />);
