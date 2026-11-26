// Shared by the server layout (inlined in <head>) and the client hook in theme.ts.
export const THEME_KEY = "sm.theme";

/** Runs before paint (pinned by hash in the CSP). Light unless the viewer chose dark or system. */
export const THEME_SCRIPT = `(function(){try{var p=localStorage.getItem("${THEME_KEY}")||"light";var d=p==="dark"||(p==="system"&&matchMedia("(prefers-color-scheme: dark)").matches);document.documentElement.dataset.theme=d?"dark":"light"}catch(e){}})()`;
