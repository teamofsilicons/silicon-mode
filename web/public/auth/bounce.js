// Native sign-in bounce (cells.md §2.3). The cell redirected here with the session in the URL
// fragment (#access_token=…&refresh_token=…&expires_at=…) or ?error=…; hand it to the app's
// custom scheme and drop it from this page's history. No network, no third-party code, no storage.
(function () {
  "use strict";
  var TARGET = "ai.tos.mode://auth/callback";
  var frag = location.hash.slice(1);
  var query = location.search;
  var url = TARGET + (frag ? "#" + frag : query);
  history.replaceState(null, "", location.pathname);

  var open = document.getElementById("open");
  var status = document.getElementById("status");
  var failed = !frag && !/[?&]error=/.test(query);
  if (open) open.setAttribute("href", failed ? "/" : url);
  if (failed) {
    var title = document.getElementById("title");
    var hint = document.getElementById("hint");
    if (title) title.textContent = "Nothing to open";
    if (status) status.textContent = "This sign-in link has already been used. Start signing in again from the app.";
    if (hint) hint.textContent = "";
    if (open) open.textContent = "Back to Silicon Mode";
    document.documentElement.setAttribute("data-waited", "");
    return;
  }
  if (/[?&]error=/.test(query) && status) status.textContent = "Sign-in was cancelled. Returning to the app…";
  location.replace(url);
  // If the app didn't take over, the button stays for a tap (Android Custom Tabs need a gesture).
  setTimeout(function () {
    document.documentElement.setAttribute("data-waited", "");
  }, 1200);
  // Clear the button's copy of the tokens once the user has had a chance to use it.
  setTimeout(function () {
    if (open) open.setAttribute("href", TARGET);
  }, 5 * 60 * 1000);
})();
