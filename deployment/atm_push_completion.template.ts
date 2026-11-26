
import {createClient} from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
const ORIGIN='https://oficinaautomotrizmedina-cmd.github.io/atm-manager/';
const PUBLIC='BPWIgiK7BXJoNdzIa-xvqiHuj-Vi0iBngRybO5bBWGNbr0nMWg0q_ubp1HwOXuufDmbqPLO2XK0vTSGSEOXfSWc';
const PRIVATE=Deno.env.get('ATM_VAPID_PRIVATE_KEY')||'';
webpush.setVapidDetails('https://oficinaautomotrizmedina-cmd.github.io/atm-manager/',PUBLIC,PRIVATE);
const base=Deno.env.get('SUPABASE_URL')||'';
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const db=createClient(base,secret,{auth:{autoRefreshToken:false,persistSession:false}});
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const output=(x,s=200)=>new Response(JSON.stringify(x),{status:s,headers});
async function sendAll(uid,payload,noticeId=null){
 const {data:subs,error}=await db.from('atm_push_subscriptions').select('id,user_id,endpoint,p256dh,auth_secret').eq('user_id',uid);
 if(error)throw error;
 let sent=0,failed=0,already=0;
 for(const sub of subs||[]){
  let claimed=false;
  if(noticeId){
   const {error:ce}=await db.from('atm_push_deliveries').insert({notice_id:noticeId,subscription_id:sub.id});
   if(ce?.code==='23505'){already++;continue;}
   if(ce){failed++;console.warn('Push claim failed',ce.message);continue;}
   claimed=true;
  }
  try{
   await webpush.sendNotification({endpoint:sub.endpoint,keys:{p256dh:sub.p256dh,auth:sub.auth_secret}},JSON.stringify(payload),{TTL:86400,urgency:'high'});
   sent++;
  }catch(ex){
   failed++;
   const code=Number(ex?.statusCode||0);
   console.error('Push failed',code,String(ex?.message||ex).slice(0,260));
   if(code===404||code===410)await db.from('atm_push_subscriptions').delete().eq('id',sub.id);
   if(claimed)await db.from('atm_push_deliveries').delete().eq('notice_id',noticeId).eq('subscription_id',sub.id);
  }
 }
 return {registered:subs?.length||0,sent,failed,already};
}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return output({error:'Método no permitido'},405);
 const jwt=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
 if(!jwt||jwt.split('.').length!==3)return output({error:'Sesión requerida'},401);
 try{
  const {data:account,error:ae}=await db.auth.getUser(jwt);
  if(ae||!account?.user)return output({error:'Sesión inválida'},401);
  const uid=account.user.id;
  const {data:profile,error:pe}=await db.from('atm_profiles').select('role,active,display_name').eq('user_id',uid).maybeSingle();
  if(pe||!profile?.active)return output({error:'Cuenta inactiva'},403);
  let b;try{b=await req.json()}catch{return output({error:'Datos incorrectos'},400)}
  if(b.action==='test'){
   // Only an authenticated user can deliberately test their own registered devices.
   // This does not create a chat message, notification-delivery claim, or recurring task.
   const payload={title:'ATM Manager · Prueba de notificación',
     body:'Notificaciones activas. Los avisos de chat deben llegar también con la aplicación cerrada.',
     url:ORIGIN,tag:'atm-push-selftest'};
   const result=await sendAll(uid,payload,null);
   return output({ok:true,test:true,...result});
  }
  if(b.action==='notice'){
    if(typeof b.notice_id!=='string'||! /^[0-9a-f-]{36}$/i.test(b.notice_id))return output({error:'Aviso inválido'},400);
    const {data:n,error:ne}=await db.from('atm_notices').select('id,author_id,target_employee_id,category,body,vehicle_caption,created_at').eq('id',b.notice_id).maybeSingle();
    if(ne||!n||n.author_id!==uid)return output({error:'Aviso no autorizado'},403);
    if(Date.now()-new Date(n.created_at).getTime()>7*86400000)return output({error:'Aviso demasiado antiguo'},400);
    let ids=[];
    if(profile.role==='admin'){
     const {data:target}=await db.from('atm_profiles').select('user_id').eq('user_id',n.target_employee_id).eq('active',true).in('role',['employee','supervisor']);
     ids=(target||[]).map(x=>x.user_id);
    }else{
     const {data:admins}=await db.from('atm_profiles').select('user_id').eq('role','admin').eq('active',true);
     ids=(admins||[]).map(x=>x.user_id);
    }
    const subject=String(n.category==='Indicación del administrador'?'Indicaciones de Grok':profile.role==='admin'?'Mensaje de Grok':n.category||'Nuevo mensaje').trim();
    const vehicle=String(n.vehicle_caption||'').trim();
    const description=String(n.body||'').trim();
    const payload={title:(subject+(vehicle?' · '+vehicle:'')).slice(0,110),body:description.length>220?description.slice(0,219)+'…':description,url:ORIGIN+'?aviso='+encodeURIComponent(n.id),tag:'atm-notice-'+n.id};
    const results=[];for(const to of new Set(ids.filter(x=>x!==uid))){results.push({user:to,...await sendAll(to,payload,n.id)});}
    return output({ok:true,results});
  }
  if(b.action==='completion'){
   // Only the authenticated employee who finalized this task can dispatch the
   // administrator's saved event. Never accept a destination or text from clients.
   if(!['employee','supervisor'].includes(profile.role))return output({error:'Aviso no autorizado'},403);
   const events=b.event_ids;
   if(!Array.isArray(events)||events.length<1||events.length>20||events.some(id=>typeof id!=='string'||! /^[0-9a-f-]{36}$/i.test(id))||new Set(events).size!==events.length)return output({error:'Aviso inválido'},400);
   const results=[];
   for(const id of events){
    const {data:event,error:ee}=await db.from('atm_calendar_changes').select('id,work_item_id,recipient_id,vehicle,detail,created_at,atm_finish_actor,atm_push_claimed_at').eq('id',id).eq('change_type','finished').eq('atm_finish_actor',uid).maybeSingle();
    if(ee||!event)return output({error:'Aviso no autorizado'},403);
    if(Date.now()-new Date(event.created_at).getTime()>7*86400000)return output({error:'Aviso demasiado antiguo'},400);
    const {data:target,error:te}=await db.from('atm_profiles').select('user_id').eq('user_id',event.recipient_id).eq('active',true).eq('role','admin').maybeSingle();
    if(te||!target||target.user_id===uid)return output({error:'Aviso no autorizado'},403);
    const claim=new Date().toISOString();
    const {data:claimed,error:ce}=await db.from('atm_calendar_changes').update({atm_push_claimed_at:claim}).eq('id',id).eq('atm_finish_actor',uid).eq('recipient_id',target.user_id).is('atm_push_claimed_at',null).select('id').maybeSingle();
    if(ce)throw ce;
    if(!claimed){results.push({sent:0,already:1,failed:0,registered:0});continue;}
    try{
     const payload={title:('Tarea finalizada · '+String(event.vehicle)).slice(0,110),body:String(event.detail).slice(0,220),url:ORIGIN+(event.work_item_id?'?trabajo='+encodeURIComponent(event.work_item_id):''),tag:'atm-completion-'+id};
     const result=await sendAll(target.user_id,payload,null);
     if(result.sent===0)await db.from('atm_calendar_changes').update({atm_push_claimed_at:null}).eq('id',id).eq('atm_push_claimed_at',claim);
     results.push(result);
    }catch(ex){
     await db.from('atm_calendar_changes').update({atm_push_claimed_at:null}).eq('id',id).eq('atm_push_claimed_at',claim);
     throw ex;
    }
   }
   return output({ok:true,results});
  }
  if(b.action==='work'){
   // Compatibility with older installed clients: calendar updates must never send push.
   return output({ok:true,skipped:true,channel:'in_app_calendar'});
  }
  return output({error:'Acción no reconocida'},400);
 }catch(e){console.error('ATM push error',String(e?.message||e).slice(0,420));return output({error:'No se pudo enviar la notificación'},500)}
});
