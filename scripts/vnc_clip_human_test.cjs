// Human-path acceptance: trusted Ctrl+V, focus-pull, and VM->browser write-back,
// driven through the clipboard bridge injected into vnc.html (no fake events).
//   - Chromium focus is emulated (CDP) so document.hasFocus() is true and the
//     clipboard APIs are permitted headless.
//   - B1: OS clipboard holds text + keyboard Ctrl+v -> TRUSTED paste event -> bridge
//         -> clipboardPasteFrom -> vdagent -> guest clipboard.
//   - B2: clipboard.writeText + window focus event -> bridge focus-pull -> guest.
//   - A : guest copies -> clipboard event -> bridge writes navigator.clipboard ->
//         page readText sees the VM text (echo guard must stop re-pasting it).
// usage: node vnc_clip_human_test.cjs <pw> <port> [marker] [b1text] [b2text]
const { chromium } = require(process.argv[2]);
const port = process.argv[3] || "8011";
const marker = process.argv[4] || "VM2HOST";
const b1 = process.argv[5] || "ctrlv_from_browser";
const b2 = process.argv[6] || "focus_pull_test";
// optional hold between B1 and B2 so an external observer can read the guest clipboard
// in the gap and attribute it to the Ctrl+V path alone.
const holdMs = parseInt(process.argv[7] || "2500", 10);
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ permissions: ["clipboard-read", "clipboard-write"] });
  const p = await ctx.newPage();
  const cdp = await ctx.newCDPSession(p);
  await cdp.send("Emulation.setFocusEmulationEnabled", { enabled: true }).catch((e) => console.log("FOCUS_EMU_FAIL=" + e.message));
  await p.goto("http://127.0.0.1:" + port + "/vnc.html", { waitUntil: "domcontentloaded", timeout: 30000 });
  const ok = await p.waitForFunction(() => {
    const c = document.querySelector("canvas");
    return !!c && c.width >= 800 && !document.getElementById("noVNC_connect_controls");
  }, null, { timeout: 60000 }).then(() => true).catch(() => false);
  console.log("PAGE_CONNECTED=" + ok);
  if (!ok) { await b.close(); return; }
  await p.waitForTimeout(2500);
  console.log("PAGE_HAS_FOCUS=" + await p.evaluate(() => document.hasFocus()));
  let b1ok = "skip";
  try {
    await p.evaluate((t) => navigator.clipboard.writeText(t), b1);
    await p.waitForTimeout(300);
    // Chromium only turns Ctrl+V into a paste event for editable focus targets, so a
    // headless probe cannot get a trusted paste on the plain noVNC document. Create a
    // throwaway contenteditable, focus it, press the REAL shortcut: Chrome fires the
    // trusted paste event, which bubbles to the bridge on document (the exact handler a
    // user's Ctrl+V hits in a real browser). We preventDefault inside so the text is not
    // inserted into the dummy element; the bridge still sees e.clipboardData.
    await p.evaluate(() => {
      const d = document.createElement("div");
      d.id = "paste-probe"; d.contentEditable = "true";
      d.style.cssText = "position:fixed;left:-2000px;top:0";
      document.body.appendChild(d);
      d.addEventListener("paste", (e) => { e.preventDefault(); }, false);
      d.focus();
    });
    await p.keyboard.press("Control+v");
    await p.evaluate(() => { const d = document.getElementById("paste-probe"); if (d) d.remove(); });
    b1ok = "sent";
  } catch (e) { b1ok = "ERR:" + e.message; }
  console.log("B1_CTRLV=" + b1ok + " text=" + b1);
  await p.waitForTimeout(holdMs);
  let b2ok = "skip";
  try {
    await p.evaluate((t) => navigator.clipboard.writeText(t), b2);
    await p.waitForTimeout(300);
    await p.evaluate(() => window.dispatchEvent(new Event("focus")));
    b2ok = "sent";
  } catch (e) { b2ok = "ERR:" + e.message; }
  console.log("B2_FOCUS_PULL=" + b2ok + " text=" + b2);
  await p.waitForTimeout(2000);
  let got = null;
  for (let i = 0; i < 10; i++) {
    await p.waitForTimeout(2000);
    const v = await p.evaluate(() => navigator.clipboard.readText().catch(() => ""));
    if (v && v.indexOf(marker) >= 0) { got = v; break; }
  }
  console.log("A_PAGE_CLIPBOARD=" + (got ? JSON.stringify(got) : "TIMEOUT"));
  await b.close();
  console.log("HUMAN_TEST_DONE");
})().catch((e) => { console.log("HUMAN_TEST_FAIL=" + e.message); process.exit(1); });
