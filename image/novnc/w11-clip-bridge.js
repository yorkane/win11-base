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
//      composing, Enter sends it AND pastes it at the caret in the VM (2026-09-06:
//      auto-paste works now that the stuck-modifier bug is fixed; 250ms is the
//      measured floor, 500ms is the shipped default). Focus
//      routing is plain browser semantics: composing keeps focus in the box, a click
//      on the canvas hands the keyboard back to the VM. The bridge NEVER swallows
//      keys or grabs focus outside the box (v7.1 -- imeGuard caused VM keyboard loss).
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
    barInput.placeholder = "本地输入法组词，回车直接粘贴到 VM 光标处";
    barInput.style.cssText = "width:340px;padding:4px 6px;border:1px solid #666;border-radius:4px;background:#111;color:#fff;";
    var bs = "padding:4px 8px;border:1px solid #666;border-radius:4px;background:#2a2a2a;color:#eee;cursor:pointer;";
    var only = document.createElement("button");
    only.id = "w11-ime-only";
    only.textContent = "粘贴 (Enter)";
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
    // Hand the keyboard back to the VM: drop the input first, then focus the canvas
    // (noVNC's Keyboard listener is bound to it; rfb.focus() is exactly canvas.focus).
    // NEVER synthesise a mousedown here: rfb.js binds focusCanvas to mousedown, so a
    // press without a matching release leaves the guest with a stuck mouse button
    // (done 2026-09-06, made focus behaviour worse -- reverted).
    if (barInput) { try { barInput.blur(); } catch (e) {} }
    var r = rfb();
    if (r && r.focus) { try { r.focus(); } catch (e) {} }
  }
  // Enter = one clipboard claim, then the human does Ctrl+V in the VM: measured fast
  // there (their own words 2026-09-06), while every bridge-side auto-strike either
  // raced the ~1s vdagent delivery (empty paste) or waited it out (unacceptable).
  // A human hand covers the delivery window for free. Keyboard injection was tested
  // too and is a dead end for CJK: nut type() emitted only the ASCII tail ('BC').
  // The guest clipboard only serves the new bytes once something opens it, which
  // costs roughly a second over QEMU->vdagent (measured earlier: guest Requests at
  // 911ms/1864ms). Auto-paste therefore claims once, waits, then strikes. Earlier
  // attempts failed for a second, independent reason too: the guest was left with
  // Ctrl+Alt held (see imeHotkey), so the V arrived as Ctrl+Alt+V and did nothing.
  // Now that releaseStuckModifiers() runs, the strike finally lands.
  function pasteStrike() {
    var r = rfb();
    if (!r || !r.sendKey) return;
    try { r.sendKey(0xffe3, "ControlLeft", true); } catch (e) { return; }
    setTimeout(function () {
      try { r.sendKey(0x76, "KeyV", true); } catch (e) {}
      setTimeout(function () {
        try { r.sendKey(0x76, "KeyV", false); } catch (e) {}
        setTimeout(function () {
          try { r.sendKey(0xffe3, "ControlLeft", false); } catch (e) {}
        }, 40);
      }, 40);
    }, 60);
  }
  function imeSubmit() {
    var r = rfb();
    if (!r || !barInput) return;
    var t = barInput.value;
    if (!t) return;
    lastSent = t;
    // Single claim (a re-NOTIFY restarts the ~1s QEMU->vdagent delivery cycle -- the
    // old ladder is what made pastes empty or late).
    try { r.clipboardPasteFrom(t); } catch (e) {}
    barInput.value = "";
    imeClose();
    // 250ms is the measured floor (150ms strikes before the guest serves the new
    // bytes and pastes the previous clipboard); 500ms keeps margin without feeling
    // slow. Single strike -- a retry would double-paste once the first lands.
    setTimeout(pasteStrike, window.__W11_PASTE_DELAY || 500);
  }

  // ---- hotkey --------------------------------------------------------------
  // ONLY Ctrl+Alt+M is intercepted, nothing else. The old imeGuard -- swallowing
  // every key while the bar was 'open' and yanking focus back on every mousedown --
  // was a keyboard hostage machine: any desync left the VM deaf (user report
  // 2026-09-06: 'keyboard dead, state stuck, only Ctrl+Alt+M recovers'). Native
  // focus routing is sufficient: keystrokes go wherever the caret is -- composing
  // in the box, VM typing after clicking the canvas. No guard needed.
  // KEY TRACE PROOF (2026-09-06): the guest receives ControlLeft DOWN and AltLeft DOWN
  // and NEVER an UP for either -- because opening the bar moves focus to the input box,
  // so the canvas-bound keyboard listener simply never sees the modifier keyups. The
  // guest is then stuck with Ctrl+Alt held and every following letter becomes a
  // shortcut ('CD' arrived as EUR, 'AFTERBAR' opened a browser link popup). Letting
  // them 'pass through' is impossible once focus has moved: we must release them
  // ourselves, explicitly, right after toggling.
  function releaseStuckModifiers() {
    var r = rfb();
    if (!r || !r.sendKey) return;
    try { r.sendKey(0xffe9, "AltLeft", false); } catch (e) {}
    try { r.sendKey(0xffe3, "ControlLeft", false); } catch (e) {}
  }
  var swallowM = false;
  function imeHotkey(e) {
    var isM = (e.code === "KeyM" || e.key === "m" || e.key === "M");
    if (swallowM && e.type === "keyup" && isM) {
      e.preventDefault();
      e.stopPropagation();
      swallowM = false;
      return;
    }
    if (!(e.ctrlKey && e.altKey && isM)) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.type === "keydown") {
      swallowM = true;
      if (bar && bar.style.display !== "none") imeClose(); else imeOpen();
      releaseStuckModifiers();
    }
  }
  document.addEventListener("keydown", imeHotkey, true);
  document.addEventListener("keyup", imeHotkey, true);
  // Safety net: a lost keyup (alt-tab, blur) must not strand the M-swallow state.
  window.addEventListener("blur", function () { swallowM = false; });

  // attach the RFB listener as soon as a session exists (UI.rfb is recreated per connect)
  var seen = null;
  setInterval(function () {
    var r = rfb();
    if (r && r !== seen) { seen = r; r.addEventListener("clipboard", onClipEvent); }
  }, 500);
})();
