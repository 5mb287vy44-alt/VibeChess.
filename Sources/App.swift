import SwiftUI
import WebKit
import AVFoundation

struct WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        v.scrollView.bounces = false
        v.scrollView.contentInsetAdjustmentBehavior = .never
        v.scrollView.pinchGestureRecognizer?.isEnabled = false
        var three = ""
        if let u = Bundle.main.url(forResource: "three.min", withExtension: "js"), let t = try? String(contentsOf: u) { three = t }
        let html = page.replacingOccurrences(of: "<!--THREE-->", with: "<script>" + three + "</script>")
        v.loadHTMLString(html, baseURL: nil)
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

@main
struct WaveApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    var body: some Scene {
        WindowGroup {
            WebView().ignoresSafeArea().background(Color.black).statusBarHidden(true).preferredColorScheme(.dark)
        }
    }
}

let page = #"""
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>WAVE · техно-демо</title>
<style>
:root{--bg:#050507;--fg:#d8d8cc;--dim:#8a8a80;--acc:#ff3b3b;box-sizing:border-box;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#050507;--fg:#d8d8cc;--dim:#8a8a80;--acc:#ff3b3b}}
:root[data-theme="dark"]{--bg:#050507;--fg:#d8d8cc;--dim:#8a8a80;--acc:#ff3b3b}
html{scroll-padding-top:env(safe-area-inset-top,0px)}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font-family:ui-monospace,Menlo,Consolas,monospace;overflow:hidden;touch-action:none;user-select:none;-webkit-user-select:none}
#c{position:fixed;inset:0;width:100%;height:100%;image-rendering:pixelated;filter:contrast(1.12) saturate(.75)}
#vhs{position:fixed;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,rgba(0,0,0,.3) 0 1px,transparent 1px 3px),radial-gradient(ellipse at center,transparent 50%,rgba(0,0,0,.7));mix-blend-mode:multiply}
#noise{position:fixed;inset:0;width:100%;height:100%;pointer-events:none;opacity:.1;image-rendering:pixelated}
#track{position:fixed;left:0;right:0;height:14px;background:rgba(255,255,255,.07);pointer-events:none;animation:tr 6s linear infinite}
@keyframes tr{from{top:-20px}to{top:100%}}
.hud{position:fixed;font-size:13px;letter-spacing:1px;text-shadow:0 0 4px #000;pointer-events:none}
#rec{left:18px;top:calc(env(safe-area-inset-top,0px) + 12px);color:var(--acc)}
#timer{right:18px;top:calc(env(safe-area-inset-top,0px) + 12px)}
#list{left:18px;top:calc(env(safe-area-inset-top,0px) + 36px);line-height:1.6;color:var(--dim)}
#toast{left:0;right:0;top:34%;text-align:center;font-size:15px;opacity:0;transition:opacity .4s}
#joy{position:fixed;left:calc(env(safe-area-inset-left,0px) + 24px);bottom:calc(env(safe-area-inset-bottom,0px) + 28px);width:120px;height:120px;border-radius:50%;border:2px solid rgba(255,255,255,.25)}
#knob{position:absolute;left:35px;top:35px;width:50px;height:50px;border-radius:50%;background:rgba(255,255,255,.25)}
button{font:inherit;color:var(--fg);background:rgba(0,0,0,.65);border:2px solid var(--fg);padding:14px 22px;letter-spacing:1px}
#act{position:fixed;right:calc(env(safe-area-inset-right,0px) + 24px);bottom:calc(env(safe-area-inset-bottom,0px) + 40px);display:none}
#screen{position:fixed;inset:0;display:none;align-items:center;justify-content:center;text-align:center;background:rgba(0,0,0,.88);padding:32px;font-size:18px;line-height:1.7;white-space:pre-line}
#choice{position:fixed;left:0;right:0;bottom:calc(env(safe-area-inset-bottom,0px) + 36px);display:none;text-align:center}
#bar{height:4px;background:var(--fg);width:60%;margin:0 auto 14px;transform-origin:left}
#choice button{margin:0 8px}
#start{position:fixed;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;background:var(--bg);text-align:center;padding:24px}
</style>
</head>
<body>
<canvas id="c"></canvas><canvas id="noise" width="96" height="54"></canvas><div id="vhs"></div><div id="track"></div>
<div class="hud" id="rec"></div><div class="hud" id="timer"></div><div class="hud" id="list"></div><div class="hud" id="toast"></div>
<div id="joy"><div id="knob"></div></div><button id="act"></button>
<div id="screen"></div>
<div id="choice"><div id="bar"></div><button id="b1"></button><button id="b2"></button></div>
<div id="start"><div style="font-size:30px;letter-spacing:4px">WAVE</div><div style="color:var(--dim);max-width:340px;line-height:1.6">Техно-демо интерактивного кино.<br>Подготовь квартиру до начала волны.<br>Джойстик слева, кнопка действия справа (на ПК: WASD и E).</div><button id="go">НАЧАТЬ</button></div>
<!--THREE-->
<script>
const $ = id => document.getElementById(id);
const R = new THREE.WebGLRenderer({canvas: $('c'), antialias: false});
R.setPixelRatio(0.55);
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x050507);
scene.fog = new THREE.Fog(0x050507, 7, 18);
const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 50);
function resize() { R.setSize(innerWidth, innerHeight, false); cam.aspect = innerWidth / innerHeight; cam.updateProjectionMatrix(); }
addEventListener('resize', resize); resize();

function box(w, h, d, x, y, z, col, em) {
  const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), new THREE.MeshStandardMaterial({color: col, emissive: em || 0x000000, roughness: 0.9}));
  m.position.set(x, y, z); scene.add(m); return m;
}
// комната
box(12, 0.1, 9, 0, -0.05, 0, 0x2a2018);
box(12, 3, 0.2, 0, 1.5, -4.6, 0x3a3a3e);
box(0.2, 3, 9, -6.1, 1.5, 0, 0x34343a);
box(0.2, 3, 9, 6.1, 1.5, 0, 0x34343a);
box(12, 0.1, 9, 0, 3.05, 0, 0x222226);
const table = box(1.6, 0.8, 1, 0.5, 0.4, 0.5, 0x4a3a2a);
box(1, 0.8, 3, -3.2, 0.4, 2, 0x3a2430);
box(0.4, 1.2, 2, -5.8, 0.6, -0.5, 0x111111);
const tvScr = new THREE.Mesh(new THREE.PlaneGeometry(1.8, 1), new THREE.MeshBasicMaterial({color: 0x335566}));
tvScr.position.set(-5.58, 1.3, -0.5); tvScr.rotation.y = Math.PI / 2; scene.add(tvScr);
const plugs = box(0.15, 0.05, 0.1, 0.5, 0.83, 0.5, 0xeeeeee);
const doorM = box(0.15, 2.4, 1.3, 5.95, 1.2, 1, 0x4a3320);
const bolt = box(0.12, 0.12, 0.12, 5.85, 1.2, 0.5, 0xd04040, 0x601010);
const win = [-3, 3].map(x => {
  const m = new THREE.Mesh(new THREE.PlaneGeometry(2, 1.4), new THREE.MeshBasicMaterial({color: 0x3a5599}));
  m.position.set(x, 1.7, -4.48); scene.add(m); return m;
});
const amb = new THREE.AmbientLight(0x222233, 0.55); scene.add(amb);
const lamp = new THREE.PointLight(0xffcc88, 0.9, 14); lamp.position.set(0, 2.6, 0); scene.add(lamp);
const tvL = new THREE.PointLight(0x5588aa, 0.5, 8); tvL.position.set(-5, 1.3, -0.5); scene.add(tvL);
const moon = new THREE.PointLight(0x4466cc, 0.5, 9); moon.position.set(0, 1.7, -4); scene.add(moon);
// игрок
const P = new THREE.Group();
const body = new THREE.Mesh(new THREE.CylinderGeometry(0.28, 0.3, 1.2, 10), new THREE.MeshStandardMaterial({color: 0x8890a0}));
body.position.y = 0.7;
const head = new THREE.Mesh(new THREE.SphereGeometry(0.22, 10, 8), new THREE.MeshStandardMaterial({color: 0xc8b8a8}));
head.position.y = 1.55;
P.add(body, head); P.position.set(0, 0, 2.6); scene.add(P);

const solids = [[-0.3, 1.3, 0, 1], [-3.7, -2.7, 0.5, 3.5], [-6.2, -5.3, -1.5, 0.5]];
const hit = (x, z) => x < -5.4 || x > 5.4 || z < -3.9 || z > 4.1 || solids.some(s => x > s[0] - 0.3 && x < s[1] + 0.3 && z > s[2] - 0.3 && z < s[3] + 0.3);

// состояние
const S = {w0: 0, w1: 0, door: 0, plugs: 0, tv: 0};
let t = 180, phase = 'idle', mv = {x: 0, z: 0}, keys = {}, rec = 0, near = null;
const toast = (s) => { const e = $('toast'); e.textContent = s; e.style.opacity = 1; clearTimeout(toast.k); toast.k = setTimeout(() => e.style.opacity = 0, 2200); };
const items = [
  {p: [-3, -3.6], r: 2.2, label: 'Закрыть окно', ok: () => !S.w0, act() { S.w0 = 1; board(0); toast('Окно закрыто плотно, без просветов'); }},
  {p: [3, -3.6], r: 2.2, label: 'Закрыть окно', ok: () => !S.w1, act() { S.w1 = 1; board(1); toast('Окно закрыто плотно, без просветов'); }},
  {p: [5.0, 1], r: 2, label: 'Запереть дверь', ok: () => !S.door, act() { S.door = 1; bolt.material.color.set(0x40d040); bolt.material.emissive.set(0x104010); toast('Замки закрыты'); }},
  {p: [0.5, 0.5], r: 2.1, label: 'Взять беруши', ok: () => !S.plugs, act() { S.plugs = 1; plugs.visible = false; if (master) master.gain.setTargetAtTime(0.3, AC.currentTime, 0.3); toast('Беруши в ушах. Звук приглушён'); }},
  {p: [-4.7, -0.5], r: 2.2, label: 'Включить телевизор', ok: () => !S.tv, act() { S.tv = 1; slides(); }}
];
function board(i) {
  win[i].material.color.set(0x150c06);
  [-0.4, 0, 0.4].forEach(o => box(2.1, 0.22, 0.1, win[i].position.x, 1.7 + o, -4.4, 0x4a3320));
}
const SL = ['ОБВМУ · подотдел ООН\nИНСТРУКЦИЯ НА ВРЕМЯ ВОЛНЫ', '1. Никому не открывать дверь.\n2. Закрыть окна плотным металлом без просветов. Закрыть щели.', '3. Отключить связь. Смотреть только заранее скачанные записи.\n4. Закрыть уши наушниками или берушами.', '5. Не спать первые 24 часа. Выбрать одну комнату и защищать её.\n6. Не верить голосам за входной дверью.'];
function slides() {
  let i = 0; const s = $('screen'); s.style.display = 'flex'; s.textContent = SL[0]; const old = phase; phase = 'read';
  s.onclick = () => { i++; if (i < SL.length) s.textContent = SL[i]; else { s.style.display = 'none'; phase = old; } };
}
// звук
let AC, master;
function audio() {
  if (AC) return;
  AC = new (window.AudioContext || window.webkitAudioContext)(); AC.resume(); master = AC.createGain(); master.gain.value = 0.8; master.connect(AC.destination);
  [55, 58.3].forEach(f => { const o = AC.createOscillator(); o.type = 'sawtooth'; o.frequency.value = f; const g = AC.createGain(); g.gain.value = 0.04; o.connect(g); g.connect(master); o.start(); });
  const b = AC.createBuffer(1, AC.sampleRate * 2, AC.sampleRate), d = b.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  const s = AC.createBufferSource(); s.buffer = b; s.loop = true; const g = AC.createGain(); g.gain.value = 0.02; s.connect(g); g.connect(master); s.start();
}
function knock() {
  if (!AC) return;
  const o = AC.createOscillator(), g = AC.createGain(); o.frequency.value = 80; g.gain.setValueAtTime(0.9, AC.currentTime); g.gain.exponentialRampToValueAtTime(0.001, AC.currentTime + 0.25);
  o.connect(g); g.connect(master); o.start(); o.stop(AC.currentTime + 0.3);
}
// волна
function ask(q, a, b, cb) {
  $('choice').style.display = 'block'; $('b1').textContent = a; $('b2').textContent = b;
  const bar = $('bar'); bar.style.transition = 'none'; bar.style.transform = 'scaleX(1)';
  requestAnimationFrame(() => { bar.style.transition = 'transform 8s linear'; bar.style.transform = 'scaleX(0)'; });
  toast(q); let done = 0;
  const pick = n => { if (done) return; done = 1; $('choice').style.display = 'none'; cb(n); };
  $('b1').onclick = () => pick(1); $('b2').onclick = () => pick(2); setTimeout(() => pick(2), 8000);
}
function ending(title, text) {
  phase = 'end'; const s = $('screen'); s.style.display = 'flex'; s.innerHTML = '<div><div style="color:var(--acc);letter-spacing:3px">' + title + '</div><br>' + text + '<br><br><button onclick="location.reload()">ЗАНОВО</button></div>';
}
function wave() {
  if (phase !== 'play') return; phase = 'wave'; toast('ВОЛНА НАЧАЛАСЬ');
  if (!S.w0 || !S.w1) win.forEach((w, i) => { if (!S['w' + i]) box(0.6, 2.2, 0.2, w.position.x, 1.1, -4.2, 0x000000); });
  setTimeout(() => { knock(); toast('Стук в дверь'); }, 3000);
  setTimeout(() => knock(), 4200); setTimeout(() => knock(), 5400);
  setTimeout(() => ask('«Это я. Открой. Мне холодно.»', 'Открыть дверь', 'Не отвечать', n => {
    if (n === 1) ending('КОНЦОВКА 1 · ГОЛОС', 'Ты нарушил главное правило.\nСвет погас. На записи остался твой смех,\nно смеялся не ты.');
    else if (!S.door) ending('КОНЦОВКА 2 · РУЧКА', 'Дверь не была заперта.\nРучка медленно повернулась вниз.');
    else if (!S.w0 || !S.w1) ending('КОНЦОВКА 3 · ПРОСВЕТ', 'Окно было закрыто не до конца.\nТо, что стояло снаружи, вошло оттуда.');
    else if (!S.plugs) ending('КОНЦОВКА 4 · ШЁПОТ', 'Без берушей ты слышал каждое слово.\nК утру ты согласился со всем, что они говорили.');
    else ending('КОНЦОВКА 5 · ПЕРВАЯ НОЧЬ', 'Ты пережил первые часы.\nОсталось 23.');
  }), 6800);
}
// управление
addEventListener('keydown', e => { keys[e.code] = 1; if (e.code === 'KeyE') act(); });
addEventListener('keyup', e => keys[e.code] = 0);
const joy = $('joy'), knob = $('knob');
function jm(e) { const r = joy.getBoundingClientRect(), x = e.clientX - r.left - 60, y = e.clientY - r.top - 60, l = Math.min(1, Math.hypot(x, y) / 50), a = Math.atan2(y, x); mv = {x: Math.cos(a) * l, z: Math.sin(a) * l}; knob.style.transform = 'translate(' + mv.x * 40 + 'px,' + mv.z * 40 + 'px)'; }
joy.addEventListener('pointerdown', e => { joy.setPointerCapture(e.pointerId); jm(e); });
joy.addEventListener('pointermove', e => { if (e.buttons || e.pressure) jm(e); });
const jend = () => { mv = {x: 0, z: 0}; knob.style.transform = ''; };
joy.addEventListener('pointerup', jend); joy.addEventListener('pointercancel', jend);
function act() { if (phase === 'play' && near) near.act(); }
$('act').onclick = act;
$('go').onclick = () => { $('start').style.display = 'none'; audio(); phase = 'play'; toast('Подготовься. Волна скоро начнётся'); };
// шум VHS
const nc = $('noise').getContext('2d'), nd = nc.createImageData(96, 54);
setInterval(() => { for (let i = 0; i < nd.data.length; i += 4) { const v = Math.random() * 255; nd.data[i] = nd.data[i + 1] = nd.data[i + 2] = v; nd.data[i + 3] = 255; } nc.putImageData(nd, 0, 0); }, 90);
// цикл
let last = performance.now();
function loop(now) {
  requestAnimationFrame(loop);
  const dt = Math.min(0.05, (now - last) / 1000); last = now;
  if (phase === 'play' || phase === 'wave') {
    let x = mv.x + (keys.KeyD || keys.ArrowRight ? 1 : 0) - (keys.KeyA || keys.ArrowLeft ? 1 : 0);
    let z = mv.z + (keys.KeyS || keys.ArrowDown ? 1 : 0) - (keys.KeyW || keys.ArrowUp ? 1 : 0);
    const l = Math.hypot(x, z);
    if (l > 0.05) {
      x /= Math.max(1, l); z /= Math.max(1, l);
      const nx = P.position.x + x * 3.2 * dt, nz = P.position.z + z * 3.2 * dt;
      if (!hit(nx, P.position.z)) P.position.x = nx;
      if (!hit(P.position.x, nz)) P.position.z = nz;
      P.rotation.y = Math.atan2(x, z);
      body.position.y = 0.7 + Math.sin(now / 90) * 0.03;
    }
  }
  if (phase === 'play') {
    t -= dt;
    const all = S.w0 && S.w1 && S.door && S.plugs && S.tv;
    if (all && t > 8) t = 8;
    if (t <= 0) wave();
    near = null; let bd = 1e9;
    items.forEach(it => { if (!it.ok()) return; const d = Math.hypot(P.position.x - it.p[0], P.position.z - it.p[1]); if (d < it.r && d < bd) { bd = d; near = it; } });
  }
  const a = $('act'); a.style.display = near && phase === 'play' ? 'block' : 'none'; if (near) a.textContent = near.label;
  const m = Math.max(0, Math.ceil(t));
  $('timer').textContent = phase === 'play' ? 'ВОЛНА ЧЕРЕЗ ' + String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0') : phase === 'wave' ? 'ВОЛНА' : '';
  rec += dt; const rs = Math.floor(rec);
  $('rec').textContent = (Math.floor(rec * 2) % 2 ? '● ' : '  ') + 'REC SP ' + String(Math.floor(rs / 3600)).padStart(2, '0') + ':' + String(Math.floor(rs / 60) % 60).padStart(2, '0') + ':' + String(rs % 60).padStart(2, '0');
  const ck = v => v ? '☑' : '☐';
  $('list').innerHTML = 'окна ' + ck(S.w0 && S.w1) + '<br>дверь ' + ck(S.door) + '<br>беруши ' + ck(S.plugs) + '<br>телевизор ' + ck(S.tv);
  lamp.intensity = (phase === 'wave' ? (Math.random() < 0.35 ? 0.05 : 0.8) : 0.9) * (0.96 + 0.04 * Math.sin(now / 40));
  tvL.intensity = 0.4 + Math.random() * 0.25; tvScr.material.color.setRGB(0.15 + Math.random() * 0.1, 0.3 + Math.random() * 0.1, 0.38);
  const sh = phase === 'wave' ? 0.06 : 0;
  cam.position.lerp(new THREE.Vector3(P.position.x * 0.8 + (Math.random() - 0.5) * sh, 5 + (Math.random() - 0.5) * sh, P.position.z + 6.2), 0.08);
  cam.lookAt(P.position.x, 1, P.position.z - 1.5);
  R.render(scene, cam);
}
requestAnimationFrame(loop);
</script>
</body>
</html>

"""#
