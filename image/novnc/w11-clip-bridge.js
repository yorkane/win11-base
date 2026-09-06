// w11-clip-bridge.js -- human clipboard + IME ergonomics on dockur's noVNC fork.
//
// Data path is ONE channel only: the RFB extended clipboard (clipboardPasteFrom /
// clipboard events) relayed by QEMU's vdagent channel. Verified by users as the
// reliable route; the mspc-API and shadow-session experiments were tried and
// REMOVED (2026-09-06): they added scheduled-task and second-session dependencies
// and made things slower/less reliable than the plain clipboard path.
//
// What this bridge adds:
//   1. paste event (Ctrl+V while the page has focus) -> clipboardPasteFrom
//   2. focus pull: on window focus read the page clipboard once, push if changed
//   3. VM -> browser: clipboard event fills the panel textarea + navigator.clipboard
//      (lastRecv echo guard prevents pushback loops)
//   4. panel Send button routed through the clipboard channel (fork made it type
//      ASCII keystrokes via rfb.sendText otherwise)
//   5. IME bar (Ctrl+Alt+M): the GUEST has no input method and Tiny11 cannot install
//      one; users type with the BROWSER-side IME. Enter pushes the composed text via
//      the clipboard channel, closes the bar and hands focus back to the VM -- the
//      user presses Ctrl+V there (their measured-fast path; 2026-09-06: 'VNC 打字很
//      快，复制粘贴也很快', auto-paste variants were the only slow thing). While the
//      bar is open the browser owns the keyboard (imeGuard) so pinyin letters never
//      leak to the guest as keystrokes.
(function () {
  "use strict";
  var lastSent = null;
  var lastRecv = null;
  // UI lives in an ES module (vnc.html does `import UI from "./app/ui.js"`), so it is
  // NOT a window global. Importing the identical specifier returns the same instance.
  var UIref = null;
  import("./app/ui.js").then(function (m) { UIref = m.default || m; }).catch(function () {});
  function rfb() { return (UIref && UIref.rfb) ? UIref.rfb : null; }
  function panelTextarea() { return document.getElementById("noVNC_clipboard_text"); }

  function pushToGuest(text, fromPanel) {
    var r = rfb();
    if (!r || text === undefined || text === null || text === "") return;
    if (text === lastRecv) return; // came FROM the VM already -- echo guard
    if (!fromPanel && text === lastSent) return;
    try { r.clipboardPasteFrom(text); lastSent = text; }
    catch (e) { /* not connected yet / view-only */ }
  }

  // 1. Ctrl+V anywhere on the page: the paste event carries the data, zero permissions.
  //   The IME bar keeps its own paste: without this the user's Ctrl+V INTO the box
  //   would be hijacked and fired at the guest instead of filling the box (2026-09-06).
  document.addEventListener("paste", function (e) {
    var r = rfb();
    if (!r) return;
    if (barInput && e.target === barInput) return;
    if (e.target && (e.target.id === "noVNC_clipboard_text" || e.target.tagName === "TEXTAREA" && !e.target.readOnly)) return;
    var t = e.clipboardData ? e.clipboardData.getData("text/plain") : "";
    if (t) { e.preventDefault(); pushToGuest(t); }
  });

  // 2. focus pull: catching copies made while the tab was away
  window.addEventListener("focus", function () {
    if (!rfb() || !navigator.clipboard || !navigator.clipboard.readText) return;
    navigator.clipboard.readText().then(function (t) { if (t) pushToGuest(t); }).catch(function () {});
  });

  // 3. VM -> browser clipboard
  function onClipEvent(ev) {
    var text = ev && ev.detail ? ev.detail.text : "";
    if (!text || text === lastRecv) return;
    lastRecv = text;
    var ta = panelTextarea();
    if (ta) { ta.value = text; ta.scrollTop = 0; }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(function () {});
    }
  }

  // 4. the fork's Send button types keystrokes; prefer the real clipboard channel.
  document.addEventListener("click", function (e) {
    if (!e.target || e.target.id !== "noVNC_clipboard_send_button") return;
    var ta = panelTextarea();
    if (!ta || !rfb()) return;
    var text = ta.value;
    if (!text) return;
    e.stopPropagation();
    pushToGuest(text, true);
  }, true);

  // ---- IME bar ------------------------------------------------------------
  var bar = null, barInput = null;
  function ensureBar() {
    if (bar) return bar;
    bar = document.createElement("div");
    bar.id = "w11-ime-bar";
    bar.style.cssText = "position:fixed;left:50%;bottom:14px;transform:translateX(-50%);z-index:1000;"
      + "display:none;gap:6px;align-items:center;background:rgba(20,20,20,.93);border:1px solid #555;"
      + "border-radius:6px;padding:6px 8px;font:13px/1.4 sans-serif;color:#ddd;";
    barInput = document.createElement("input");
    barInput.id = "w11-ime-input";
    barInput.setAttribute("lang", "zh-Hans");
    barInput.autocomplete = "off";
    barInput.placeholder = "本地输入法组词，回车送入剪贴板，然后在 VM 里 Ctrl+V";
    barInput.style.cssText = "width:340px;padding:4px 6px;border:1px solid #666;border-radius:4px;background:#111;color:#fff;";
    var bs = "padding:4px 8px;border:1px solid #666;border-radius:4px;background:#2a2a2a;color:#eee;cursor:pointer;";
    var only = document.createElement("button");
    only.id = "w11-ime-only";
    only.textContent = "送入剪贴板 (Enter)";
    only.style.cssText = bs;
    only.addEventListener("click", function () { imeSubmit(); });
    barInput.addEventListener("keydown", function (e) {
      // 组词期间（isComposing / keyCode 229）的回车属于输入法候选键，不能当发送
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === "Enter") { e.preventDefault(); imeSubmit(); }
      else if (e.key === "Escape") { e.preventDefault(); imeClose(); }
    });
    bar.appendChild(barInput); bar.appendChild(only);
    document.body.appendChild(bar);
    return bar;
  }
  function imeOpen() {
    ensureBar();
    bar.style.display = "flex";
    barInput.focus();
    barInput.select();
  }
  function imeClose() {
    if (!bar) return;
    bar.style.display = "none";
    var r = rfb();
    if (r && r.focus) { try { r.focus(); } catch (e) {} }
  }
  // Enter = one clipboard claim, then the human does Ctrl+V in the VM: measured fast
  // there (their own words 2026-09-06), while every bridge-side auto-strike either
  // raced the ~1s vdagent delivery (empty paste) or waited it out (unacceptable).
  // A human hand covers the delivery window for free. Keyboard injection was tested
  // too and is a dead end for CJK: nut type() emitted only the ASCII tail ('BC').
  function imeSubmit() {
    var r = rfb();
    if (!r || !barInput) return;
    var t = barInput.value;
    if (!t) return;
    lastSent = t;
    // Single claim (a re-NOTIFY restarts the ~1s QEMU->vdagent delivery cycle -- the
    // old ladder is what made pastes empty or late). The push happens on BOTH paths;
    // a 2026-09-06 regression moved it inside the paste branch and silently broke
    // 'only to clipboard'.
    try { r.clipboardPasteFrom(t); } catch (e) { return; }
    // Phrase spent: clear the box (no silent concatenation next round), then hand
    // the keyboard to the VM so the very next Ctrl+V -- wherever the caret sits --
    // is the guest's. imeClose() refocuses the RFB canvas.
    barInput.value = "";
    imeClose();
  }

  // ---- IME-mode guard ------------------------------------------------------
  // While the bar is OPEN the browser owns the keyboard: clicks still reach the VM
  // (caret placement), keystrokes on the canvas are swallowed (noVNC would forward
  // raw pinyin letters as ASCII) and focus is pulled back -- noVNC refocuses its
  // canvas ~100ms after mousedown, hence the deferred re-focus below.
  function imeToggle(e) {
    if (bar && bar.style.display !== "none") imeClose(); else imeOpen();
    if (e) { e.preventDefault(); e.stopPropagation(); }
  }
  function imeGuard(e) {
    // hotkey works in BOTH states, tested BEFORE the visibility guard; only keydown
    // toggles (keyup of the same combo would immediately toggle back).
    if (e.ctrlKey && e.altKey && (e.code === "KeyM" || e.key === "m" || e.key === "M")) {
      if (e.type === "keydown") imeToggle(e); else { e.preventDefault(); e.stopPropagation(); }
      return;
    }
    if (!bar || bar.style.display === "none") return;
    if (e.target === barInput) return;
    if (e.key === "Escape") { imeToggle(e); return; }
    e.preventDefault(); e.stopPropagation();
    if (barInput) { try { barInput.focus(); } catch (x) {} }
  }
  document.addEventListener("keydown", imeGuard, true);
  document.addEventListener("keyup", imeGuard, true);
  document.addEventListener("keypress", imeGuard, true);
  document.addEventListener("paste", imeGuard, true);
  document.addEventListener("mousedown", function (e) {
    if (!bar || bar.style.display === "none" || e.target === barInput) return;
    setTimeout(function () { if (bar && bar.style.display !== "none") { try { barInput.focus(); } catch (x) {} } }, 0);
  }, true);

  // attach the RFB listener as soon as a session exists (UI.rfb is recreated per connect)
  var seen = null;
  setInterval(function () {
    var r = rfb();
    if (r && r !== seen) { seen = r; r.addEventListener("clipboard", onClipEvent); }
  }, 500);
})();
