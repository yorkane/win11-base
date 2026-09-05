// w11-clip-bridge.js -- restore human clipboard ergonomics on top of dockur's noVNC fork.
//
// Why: upstream noVNC binds Ctrl+V (a document "paste" event) to rfb.clipboardPasteFrom.
// dockur's 1.7.0 fork removed that binding and turned the panel's "Send clipboard" button
// into rfb.sendText() (keystroke typing, ASCII-only, Chinese becomes garbage). The wire
// protocol itself is intact -- vdagent relays extended clipboard both ways (verified
// 2026-09-05: browser paste -> guest clipboard, guest copy -> clipboard event).
//
// This bridge adds, and nothing else:
//   1. paste event (Ctrl+V / right-click Paste while the page has focus) -> clipboardPasteFrom
//   2. focus-triggered clipboard poll: on window focus, read the page clipboard once and
//      push it if it changed (no background polling -- Chromium restricts readText to
//      focused documents anyway)
//   3. VM -> browser: on the RFB "clipboard" event, fill the panel textarea AND write
//      navigator.clipboard when the permission is granted (Chrome asks once)
//   4. make the panel "Send clipboard" button use the clipboard channel instead of typing
//      keystrokes (capture-phase click intercept).
(function () {
  "use strict";
  var lastSent = null;   // avoid re-pushing identical text on every focus
  var lastRecv = null;
  // UI lives in an ES module (vnc.html does `import UI from "./app/ui.js"`), so it is NOT
  // a window global. Same URL = same module instance, so importing the identical specifier
  // hands us the very UI object the page uses, including its live rfb property.
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
  document.addEventListener("paste", function (e) {
    var r = rfb();
    if (!r) return;
    // do not hijack pastes into the panel textarea itself -- let the user edit it
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

  // 4. the fork's Send button types keystrokes; prefer the real clipboard channel. Capture
  // phase runs before ui.js's handler; we do the send and stop the keystroke version.
  document.addEventListener("click", function (e) {
    if (!e.target || e.target.id !== "noVNC_clipboard_send_button") return;
    var ta = panelTextarea();
    if (!ta || !rfb()) return;
    var text = ta.value;
    if (!text) return;
    e.stopPropagation();
    pushToGuest(text, true);
  }, true);

  // attach the RFB listener as soon as a session exists (UI.rfb is recreated per connect)
  var seen = null;
  setInterval(function () {
    var r = rfb();
    if (r && r !== seen) { seen = r; r.addEventListener("clipboard", onClipEvent); }
  }, 500);
})();
