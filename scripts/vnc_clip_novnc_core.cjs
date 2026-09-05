// Browser acceptance for the clipboard bridge, running the image's OWN noVNC core code
// inside real Chromium: import ./core/rfb.js (same module the page uses), open a second
// shared session over websockify, and exercise the two clipboard paths:
//   B: rfb.clipboardPasteFrom(text) -> extended Notify -> server Request -> Provide
//      -> qemu-vdagent -> guest clipboard (a user's Ctrl+V calls the very same method).
//   A: guest copies -> vdagent -> ServerCutText -> RFB fires the "clipboard" event.
// usage: node vnc_clip_novnc_core.cjs <pw> <port> <marker> <textB>
const { chromium } = require(process.argv[2]);
const port = process.argv[3] || "8011";
const marker = process.argv[4] || "VM2HOST";
const textB = process.argv[5] || ("browser-paste-" + Date.now());
(async () => {
  const b = await chromium.launch();
  const p = await (await b.newContext()).newPage();
  await p.goto("http://127.0.0.1:" + port + "/vnc.html", { waitUntil: "domcontentloaded", timeout: 30000 });
  const ok = await p.waitForFunction(() => {
    const c = document.querySelector("canvas");
    return !!c && c.width >= 800 && !document.getElementById("noVNC_connect_controls");
  }, null, { timeout: 60000 }).then(() => true).catch(() => false);
  console.log("PAGE_CONNECTED=" + ok);
  const out = await p.evaluate(async (args) => {
    const ns = await import("./core/rfb.js");
    const holder = document.createElement("div");
    holder.id = "probe-holder";
    document.body.appendChild(holder);
    const ws = new WebSocket("ws://" + location.host + "/websockify", ["binary"]);
    ws.binaryType = "arraybuffer";
    const RFB = ns.default;
    const rfb = new RFB(holder, ws, { shared: true, credentials: {} });
    // viewOnly must stay OFF: clipboardPasteFrom() returns early when viewOnly is set.
    window.__probe = { rfb, clip: [], err: null, connected: false };
    rfb.addEventListener("connect", () => { window.__probe.connected = true; });
    rfb.addEventListener("clipboard", (ev) => window.__probe.clip.push(ev.detail.text));
    rfb.addEventListener("securityfailure", (ev) => { window.__probe.err = "sec:" + JSON.stringify(ev.detail); });
    rfb.addEventListener("fail", (ev) => { window.__probe.err = "fail:" + (ev.detail && ev.detail.reason); });
    return "probe-created";
  }, null);
  console.log("PROBE=" + out);
  const conn = await p.waitForFunction(() => window.__probe && window.__probe.connected, null, { timeout: 20000 }).then(() => true).catch(() => false);
  console.log("PROBE_CONNECTED=" + conn);
  await p.waitForTimeout(2000);
  const paste = await p.evaluate((t) => {
    try { window.__probe.rfb.clipboardPasteFrom(t); return "pasted"; } catch (e) { return "ERR:" + e.message; }
  }, textB);
  console.log("B_CLIPBOARD_PASTE=" + paste + " text=" + textB);
  let got = null;
  for (let i = 0; i < 12; i++) {
    await p.waitForTimeout(2000);
    const arr = await p.evaluate(() => window.__probe.clip.slice());
    const hit = arr.find((t) => t && t.indexOf(marker) >= 0);
    if (hit) { got = hit; break; }
  }
  console.log("A_CLIP_EVENT=" + (got ? JSON.stringify(got) : "TIMEOUT"));
  const err = await p.evaluate(() => window.__probe.err);
  console.log("PROBE_ERR=" + (err || "none"));
  await b.close();
  console.log("NOVNC_CORE_TEST_DONE");
})().catch((e) => { console.log("NOVNC_CORE_FAIL=" + e.message); process.exit(1); });
