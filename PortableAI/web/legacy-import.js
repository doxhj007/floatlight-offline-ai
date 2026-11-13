(() => {
  'use strict';
  const MAX_IMPORT_BYTES = 30 * 1024 * 1024;
  const timeout = (promise, ms, label) => Promise.race([promise,new Promise((_,reject)=>setTimeout(()=>reject(new Error(label+'超时')),ms))]);
  const requestResult = (request) => new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error||new Error('读取失败'));});
  async function existingDatabaseNames(){ if(typeof indexedDB.databases!=='function')return [];try{return(await indexedDB.databases()).map(x=>x.name).filter(Boolean);}catch{return [];} }
  async function openExisting(name){
    const names=await existingDatabaseNames(); if(!names.includes(name))return null;
    return timeout(new Promise((resolve,reject)=>{const req=indexedDB.open(name);req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error||new Error('无法打开 '+name));req.onupgradeneeded=()=>{req.transaction.abort();reject(new Error('旧数据库不存在'));};}),8000,'打开旧聊天');
  }
  async function allFrom(db,store){ if(!db.objectStoreNames.contains(store))return [];return timeout(new Promise((resolve,reject)=>{const tx=db.transaction(store,'readonly'),req=tx.objectStore(store).getAll();req.onsuccess=()=>resolve(req.result||[]);req.onerror=()=>reject(req.error||new Error('无法读取 '+store));tx.onabort=()=>reject(tx.error||new Error('读取已中止'));}),15000,'读取旧聊天'); }
  function when(value,fallback=Date.now()){let n=Number(value);if(!Number.isFinite(n))n=fallback;if(n>0&&n<1e12)n*=1000;const d=new Date(n);return Number.isNaN(d.getTime())?new Date(fallback):d;}
  function contentText(value){if(typeof value==='string')return value;if(value==null)return '';try{return JSON.stringify(value);}catch{return String(value);}}
  function base64(bytes){let result='';const size=32768;for(let i=0;i<bytes.length;i+=size)result+=String.fromCharCode(...bytes.subarray(i,i+size));return btoa(result);}
  async function jsonSafe(value,seen=new WeakSet(),depth=0){
    if(value==null||typeof value==='string'||typeof value==='number'||typeof value==='boolean')return value;
    if(typeof value==='bigint')return value.toString(); if(depth>30)return '[层级过深]';
    if(value instanceof Date)return value.toISOString();
    if(value instanceof Blob){const bytes=new Uint8Array(await value.arrayBuffer());return{$type:'Blob',mime:value.type||'',base64:base64(bytes)};}
    if(value instanceof ArrayBuffer)return{$type:'ArrayBuffer',base64:base64(new Uint8Array(value))};
    if(ArrayBuffer.isView(value))return{$type:value.constructor.name,base64:base64(new Uint8Array(value.buffer,value.byteOffset,value.byteLength))};
    if(typeof value==='object'){if(seen.has(value))return '[循环引用]';seen.add(value);let out;if(Array.isArray(value)){out=[];for(const item of value)out.push(await jsonSafe(item,seen,depth+1));}else{out={};for(const key of Object.keys(value))out[key]=await jsonSafe(value[key],seen,depth+1);}seen.delete(value);return out;}
    return String(value);
  }
  async function stableUuid(text){const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)));hash[6]=(hash[6]&15)|128;hash[8]=(hash[8]&63)|128;const hex=[...hash.slice(0,16)].map(x=>x.toString(16).padStart(2,'0')).join('');return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20,32);}
  function currentBranch(conversation,all){
    const map=new Map(all.map(m=>[String(m.id),m]));let node=map.get(String(conversation.currNode||''));if(!node)node=all.filter(m=>m&&m.type!=='root').sort((a,b)=>when(a.timestamp,0)-when(b.timestamp,0)).at(-1);
    const branch=[],seen=new Set();while(node&&!seen.has(String(node.id))){seen.add(String(node.id));if(node.type!=='root')branch.unshift(node);if(node.parent==null)break;node=map.get(String(node.parent));}
    return branch;
  }
  function convertedMessages(branch){const result=[];for(const old of branch){let role=String(old.role||'assistant');if(role==='tool')role='assistant';if(!['user','assistant','system'].includes(role))continue;let text=contentText(old.content);if(old.role==='tool'&&text)text='[工具结果]\n'+text;if(!text&&old.reasoningContent)text=contentText(old.reasoningContent);if(!text)continue;result.push({id:String(old.id||crypto.randomUUID()),role,content:text,createdAt:when(old.timestamp).toISOString(),model:old.model?String(old.model):undefined});}return result;}
  async function postImport(cfg,payload){const body=JSON.stringify(payload);if(new TextEncoder().encode(body).length>MAX_IMPORT_BYTES)throw new Error('一段旧聊天超过 30 MB，已保留原数据库，未迁移这段记录');const response=await fetch(cfg.storageUrl+'/api/import',{method:'POST',headers:{'Authorization':'Bearer '+cfg.token,'Content-Type':'application/json'},body});let data={};try{data=await response.json();}catch{}if(!response.ok)throw new Error(data.error||('导入失败 '+response.status));return data;}
  window.cleanupLegacyUi=async function(){
    try{if('serviceWorker'in navigator){const regs=await navigator.serviceWorker.getRegistrations();await Promise.all(regs.filter(r=>r.scope.startsWith(location.origin+'/')).map(r=>r.unregister()));}}
    catch{}
    try{if('caches'in window){const names=await caches.keys();await Promise.all(names.filter(n=>/workbox|llama/i.test(n)).map(n=>caches.delete(n)));}}
    catch{}
  };
  window.importLegacyChats=async function(cfg){
    if(!cfg||!cfg.storageUrl||!cfg.token)return{imported:0,skipped:0,error:'启动配置缺失'};
    const available=await existingDatabaseNames();const preferred=[];if(available.includes('LlamaUi'))preferred.push('LlamaUi');for(const name of available)if(/^llamacppwebui$/i.test(name)&&!preferred.includes(name))preferred.push(name);if(!preferred.length)return{imported:0,skipped:0};
    let imported=0,skipped=0;const errors=[],seenConversations=new Set();
    for(const dbName of preferred){let db;try{db=await openExisting(dbName);if(!db)continue;const [conversations,messages,groups]=await Promise.all([allFrom(db,'conversations'),allFrom(db,'messages'),allFrom(db,'groups')]);
      for(const conversation of conversations){const oldId=String(conversation&&conversation.id||'');if(!oldId||seenConversations.has(oldId)){skipped++;continue;}seenConversations.add(oldId);const all=messages.filter(m=>String(m&&m.convId||'')===oldId);const branch=currentBranch(conversation,all),converted=convertedMessages(branch);if(!converted.length){skipped++;continue;}const created=converted.reduce((a,m)=>when(m.createdAt)<a?when(m.createdAt):a,when(converted[0].createdAt));const updated=when(conversation.lastModified,when(converted.at(-1).createdAt).getTime());const id=await stableUuid('PortableAI legacy '+oldId);const relevantGroup=groups.find(g=>String(g&&g.id||'')===String(conversation.groupId||''));const chat={schemaVersion:1,id,legacyId:'llama:'+oldId,title:String(conversation.name||'旧聊天'),createdAt:created.toISOString(),updatedAt:updated.toISOString(),revision:0,messages:converted};const raw=await jsonSafe({database:dbName,conversation,messages:all,group:relevantGroup||null});try{const result=await postImport(cfg,{source:dbName,conversations:[chat],raw});imported+=Number(result.imported||0);skipped+=Number(result.skipped||0);}catch(error){errors.push((conversation.name||oldId)+'：'+error.message);}}
    }catch(error){errors.push(dbName+'：'+error.message);}finally{if(db)db.close();}}
    return{imported,skipped,error:errors.length?errors.slice(0,3).join('；'):''};
  };
})();