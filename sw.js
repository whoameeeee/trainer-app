const CACHE='prodvizhenie-shell-v73';const FILES=['./','./index.html','./manifest.json','./icon.svg','./icon-192.png','./icon-512.png','./config.js','./exercises.html','./exercises-data.js','./studio.html','./finance.html','./client-links.html'];self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(FILES)).then(()=>self.skipWaiting())));self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return;if(new URL(e.request.url).origin!==self.location.origin){if(e.request.url.includes('cdn.jsdelivr.net/npm/@supabase/supabase-js'))e.respondWith(caches.open(CACHE).then(async c=>{try{let r=await fetch(e.request);if(r.ok||r.type==='opaque')await c.put(e.request,r.clone());return r}catch{return (await c.match(e.request))||Response.error()}}));return;}e.respondWith(fetch(e.request).then(r=>{if(r.ok){let copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy))}return r}).catch(()=>caches.match(e.request)))});
// Обработчики фоновых Web Push для будущего серверного подключения.
self.addEventListener('push',event=>{
 let payload={};try{payload=event.data?.json()||{}}catch{}
 // Не отображаем персональные данные клиента в уведомлении.
 event.waitUntil(self.registration.showNotification('Продвижение · расписание',{
  body:payload.kind==='schedule_change'?'Ваше расписание изменилось':'Проверьте ближайшие тренировки',
  icon:'./icon-192.png',badge:'./icon-192.png',tag:'prodvizhenie-'+(payload.kind||'schedule'),data:{url:'./index.html'}
 }));
});
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(async windows=>{for(const w of windows){if(w.url.startsWith(self.registration.scope)){await w.focus();return}}return clients.openWindow('./index.html')}))});
