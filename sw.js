const CACHE='atm-manager-shell-v31';
self.addEventListener('install',event=>{self.skipWaiting()});
self.addEventListener('activate',event=>{event.waitUntil(self.clients.claim())});
self.addEventListener('fetch',event=>{
 if(event.request.method!=='GET')return;
 if(event.request.mode==='navigate'){
  event.respondWith(fetch(event.request,{cache:'no-store'}).catch(()=>new Response('<h2>ATM Manager: se necesita conexión a internet</h2>',{headers:{'Content-Type':'text/html; charset=utf-8'}})));
 }
});
self.addEventListener('push',event=>{
 let data={title:'ATM Manager',body:'Tenés un nuevo aviso.',url:self.registration.scope};
 try{if(event.data)data={...data,...event.data.json()}}catch(_){if(event.data)data.body=event.data.text()}
 const options={body:String(data.body||'Tenés un nuevo aviso.').slice(0,220),icon:'./icon-192.png',badge:'./icon-192.png',tag:data.tag||undefined,renotify:false,data:{url:data.url||self.registration.scope},vibrate:[200,100,200]};
 event.waitUntil(self.registration.showNotification(data.title||'ATM Manager',options));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();
 const candidate=event.notification.data?.url||self.registration.scope;
 const target=new URL(candidate,self.registration.scope);
 if(target.origin!==self.location.origin||!target.pathname.startsWith(new URL(self.registration.scope).pathname))return;
 event.waitUntil((async()=>{
  const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
  for(const client of windows){
   try{const p=new URL(client.url);if(p.origin===target.origin&&p.pathname===target.pathname){
    if('navigate' in client)await client.navigate(target.href);
    return client.focus();
   }}catch(_){}
  }
  return self.clients.openWindow(target.href);
 })());
});
