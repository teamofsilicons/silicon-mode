import Foundation

/// The page the browser lands on after the cell's hosted sign-in (http://127.0.0.1:47291/auth/callback).
/// Silicon Accounts look: flat paper, neutral greys, Allo (ROND 20, served from the app bundle),
/// the silicon gradient, faint warm shadows. A half-open laptop glyph whose lid settles at the
/// "Silicon Mode angle" when sign-in completes. No third-party anything: tokens pass through here.
enum LoopbackPage {
    static func csp(nonce: String) -> String {
        "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; font-src 'self'; "
            + "connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static func html(secret: String, nonce: String) -> String {
        template
            .replacingOccurrences(of: "__SECRET__", with: secret)
            .replacingOccurrences(of: "__NONCE__", with: nonce)
    }

    private static let template = #"""
<!doctype html>
<html lang="en" data-state="pending">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<title>Silicon Mode</title>
<style>
@font-face{font-family:"Allo";src:url(/assets/allo.ttf) format("truetype");font-weight:100 900;font-display:swap}
:root{
  --bg:#F8F8F8;--card:#FFFFFF;--fg:#1B1B1B;--muted:#6B6B6B;--faint:#A4A4A4;--border:#E9E9E9;
  --accent:#3460F0;--accent-fg:#FFFFFF;--g1:#E2D8F8;--g2:#FADFC6;--ink1:#644C8A;--ink2:#8A542D;--danger:#B42318;
  --pill:#F1F1F1;
  --shadow:0 1px 2px rgba(70,45,20,.05),0 2px 6px -2px rgba(70,45,20,.05),0 28px 60px -24px rgba(90,60,25,.16);
  --spring:cubic-bezier(.34,1.56,.64,1);--ease:cubic-bezier(.22,1,.36,1);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0F0F0F;--card:#191919;--fg:#F2F2F2;--muted:#8C8C8C;--faint:#4D4D4D;--border:#2B2B2B;
  --accent:#7D9BFF;--accent-fg:#141414;--g1:#CBBAEB;--g2:#EDCAA3;--ink1:#463C59;--ink2:#5A422F;--danger:#F4968C;
  --pill:#242424;
  --shadow:0 1px 2px rgba(0,0,0,.5),0 30px 80px -30px rgba(0,0,0,.8);
}}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{background:var(--bg);color:var(--fg);display:grid;place-items:center;padding:24px;
  font-family:"Allo","Allo Variable",system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  font-variation-settings:"ROND" 20;font-optical-sizing:auto;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
.card{position:relative;width:min(420px,100%);background:var(--card);border:1px solid var(--border);border-radius:28px;
  box-shadow:var(--shadow);padding:44px 36px 30px;text-align:center;
  animation:rise .7s var(--ease) both}
@keyframes rise{from{opacity:0;transform:translateY(10px) scale(.985)}to{opacity:1;transform:none}}
.orb{position:relative;width:88px;height:88px;margin:0 auto;border-radius:30px;
  background:linear-gradient(135deg,var(--g1),var(--g2));display:grid;place-items:center}
.orb::after{content:"";position:absolute;inset:-1px;border-radius:31px;border:1px solid rgba(255,255,255,.35);pointer-events:none}
.ring{position:absolute;inset:0;border-radius:30px;border:2px solid var(--g2);opacity:0}
[data-state=ok] .ring{animation:ring 1.4s var(--ease) .15s both}
@keyframes ring{from{opacity:.9;transform:scale(1)}to{opacity:0;transform:scale(1.55)}}
svg.mac{width:58px;height:58px;overflow:visible}
.mac .base{stroke:var(--ink1)}
.mac .lid{stroke:url(#ink);transform-origin:16px 50px;transform-box:view-box;transform:rotate(-104deg);
  animation:swing 1.5s ease-in-out infinite alternate}
@keyframes swing{from{transform:rotate(-108deg)}to{transform:rotate(-70deg)}}
[data-state=ok] .mac .lid{animation:settle .9s var(--spring) forwards}
@keyframes settle{to{transform:rotate(-62deg)}}
[data-state=error] .mac .lid{animation:none;transform:rotate(-108deg);transition:transform .5s var(--ease)}
.badge{position:absolute;right:-8px;bottom:-8px;width:32px;height:32px;border-radius:50%;
  background:var(--accent);color:var(--accent-fg);display:grid;place-items:center;
  box-shadow:0 0 0 4px var(--card);transform:scale(0);opacity:0}
[data-state=ok] .badge{animation:pop .6s var(--spring) .35s forwards}
[data-state=error] .badge{background:var(--danger);animation:pop .5s var(--spring) .1s forwards}
@keyframes pop{to{transform:scale(1);opacity:1}}
.badge svg{width:16px;height:16px}
.badge .check{stroke-dasharray:24;stroke-dashoffset:24}
[data-state=ok] .badge .check{animation:draw .45s var(--ease) .6s forwards}
@keyframes draw{to{stroke-dashoffset:0}}
.badge .bang{display:none}
[data-state=error] .badge .check{display:none}
[data-state=error] .badge .bang{display:block}
h1{font-size:24px;font-weight:600;letter-spacing:-.03em;line-height:1.12;margin-top:28px}
p{font-size:15px;line-height:1.45;color:var(--muted);letter-spacing:-.01em;margin:10px auto 0;max-width:320px}
.swap{animation:fade .45s var(--ease) both}
@keyframes fade{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
.who{display:inline-flex;align-items:center;gap:10px;margin-top:22px;padding:5px 14px 5px 5px;border-radius:999px;
  background:var(--pill);font-size:14px;letter-spacing:-.01em;animation:fade .5s var(--ease) .45s both}
.who[hidden]{display:none}
.av{width:28px;height:28px;border-radius:50%;background:linear-gradient(135deg,var(--g1),var(--g2));color:#1B1A1F;
  display:grid;place-items:center;font-weight:600;font-size:13px}
.who b{font-weight:500}
.who span{color:var(--muted);font-variant-numeric:tabular-nums}
.dots{display:inline-flex;gap:5px;margin-top:22px}
.dots i{width:6px;height:6px;border-radius:50%;background:var(--faint);animation:dot 1.2s ease-in-out infinite}
.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}
@keyframes dot{0%,80%,100%{opacity:.35;transform:translateY(0)}40%{opacity:1;transform:translateY(-3px)}}
[data-state=ok] .dots,[data-state=error] .dots{display:none}
.foot{margin-top:30px;padding-top:18px;border-top:1px solid var(--border);font-size:12px;color:var(--faint);
  display:flex;justify-content:center;gap:6px;align-items:center;letter-spacing:0}
.foot .g{width:8px;height:8px;border-radius:3px;background:linear-gradient(135deg,var(--g1),var(--g2))}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition:none!important}
  .mac .lid{transform:rotate(-90deg)}[data-state=ok] .mac .lid{transform:rotate(-62deg)}}
</style>
</head>
<body>
<main class="card" role="status" aria-live="polite">
  <div class="orb">
    <span class="ring"></span>
    <svg class="mac" viewBox="0 0 64 64" fill="none" stroke-width="5" stroke-linecap="round" aria-hidden="true">
      <defs><linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="64" y2="64"><stop offset="0" style="stop-color:var(--ink1)"/><stop offset="1" style="stop-color:var(--ink2)"/></linearGradient></defs>
      <line class="base" x1="16" y1="50" x2="56" y2="50"/>
      <line class="lid" x1="16" y1="50" x2="54" y2="50"/>
    </svg>
    <span class="badge" aria-hidden="true">
      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">
        <path class="check" d="M3.5 8.4l3 3 6-6.6"/>
        <path class="bang" d="M8 3.5v5.2M8 12.2v.1"/>
      </svg>
    </span>
  </div>
  <h1 id="t">Finishing sign-in…</h1>
  <p id="m">Handing your Silicon account to Silicon Mode.</p>
  <div class="dots" aria-hidden="true"><i></i><i></i><i></i></div>
  <div class="who" id="who" hidden><span class="av" id="av"></span><b id="wn"></b><span id="wh"></span></div>
  <div class="foot"><span class="g"></span>Silicon Mode · this page only talks to your Mac</div>
</main>
<script nonce="__NONCE__">
(function(){
  var frag = location.hash ? location.hash.slice(1) : "";
  var q = location.search ? location.search.slice(1) : "";
  try { history.replaceState(null, "", "/auth/callback"); } catch (e) {}
  var root = document.documentElement;
  function swap(id, text){ var el = document.getElementById(id); el.textContent = text; el.classList.remove("swap"); void el.offsetWidth; el.classList.add("swap"); }
  function show(r){
    root.setAttribute("data-state", r.ok ? "ok" : "error");
    swap("t", r.title || (r.ok ? "You're signed in" : "Sign-in didn't finish"));
    swap("m", r.message || "");
    if (r.ok && (r.name || r.handle)) {
      document.getElementById("who").hidden = false;
      document.getElementById("wn").textContent = r.name || "";
      document.getElementById("wh").textContent = r.handle || "";
      document.getElementById("av").textContent = ((r.name || r.handle || "?").trim().charAt(0) || "?").toUpperCase();
    }
    document.title = r.ok ? "Signed in · Silicon Mode" : "Silicon Mode";
  }
  if (!frag && !q) {
    show({ok:false, title:"Nothing to finish here", message:"This page completes a sign-in started from Silicon Mode. Start again from the menu bar."});
    return;
  }
  fetch("/auth/complete", {method:"POST", cache:"no-store", credentials:"omit", referrerPolicy:"no-referrer",
    headers:{"Content-Type":"application/json","X-Silicon-Mode":"__SECRET__"},
    body:JSON.stringify({fragment:frag, query:q})})
    .then(function(r){ return r.json(); })
    .then(show)
    .catch(function(){ show({ok:false, title:"Silicon Mode isn't listening", message:"This sign-in window has closed. Start again from the Silicon Mode menu bar."}); });
})();
</script>
</body>
</html>
"""#
}
