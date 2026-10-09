const CACHE='atm-manager-shell-v29';
self.addEventListener('install',e=>{self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(self.clients.claim())});
self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return; if(e.request.mode==='navigate'){e.respondWith(fetch(e.request).catch(()=>new Response('<h2>ATM Manager: conexión a internet necesaria</h2>',{headers:{'Content-Type':'text/html; charset=utf-8'}})));}});
