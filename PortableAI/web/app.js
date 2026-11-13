(() => {
  'use strict';
  const cfg = window.PORTABLE_AI_CONFIG || {};
  const $ = id => document.getElementById(id);
  const ui = {
    sidebar:$('sidebar'),backdrop:$('backdrop'),openSidebar:$('openSidebar'),closeSidebar:$('closeSidebar'),
    newChat:$('newChat'),refreshHistory:$('refreshHistory'),historyList:$('historyList'),storageDot:$('storageDot'),
    storageState:$('storageState'),storagePath:$('storagePath'),chatTitle:$('chatTitle'),modelLabel:$('modelLabel'),
    copyPath:$('copyPath'),chatScroll:$('chatScroll'),welcome:$('welcome'),messages:$('messages'),
    composerWrap:document.querySelector('.composer-wrap'),composer:$('composer'),prompt:$('prompt'),send:$('send'),stop:$('stop'),
    notice:$('notice'),saveState:$('saveState'),modeHint:$('modeHint'),attachImage:$('attachImage'),imageMode:$('imageMode'),
    imageInput:$('imageInput'),attachmentStrip:$('attachmentStrip'),welcomeVision:$('welcomeVision'),welcomeImage:$('welcomeImage'),
    editStrip:$('editStrip'),cancelEdit:$('cancelEdit'),dialogBackdrop:$('dialogBackdrop'),dialogMark:$('dialogMark'),
    dialogTitle:$('dialogTitle'),dialogText:$('dialogText'),dialogInput:$('dialogInput'),dialogCancel:$('dialogCancel'),dialogConfirm:$('dialogConfirm')
  };
  let current=null,histories=[],modelId=cfg.model||'',generating=false,generatingKind='',aborter=null;
  let saveChain=Promise.resolve(),saveTimer=null,storageLocked=false,lastSavedPath=cfg.storageRoot||'F:\\AI聊天记录',noticeTimer=null;
  let composeMode='chat',pendingImages=[],editingMessageId='',dialogResolve=null;

  const isoNow=()=>new Date().toISOString();
  const uuid=()=>crypto.randomUUID?crypto.randomUUID():'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const r=Math.random()*16|0;return(c==='x'?r:(r&3|8)).toString(16);});
  const escapePath=path=>String(path||'').replace(/\\+/g,'\\');
  const shortTime=value=>{const d=new Date(value);return Number.isNaN(d.getTime())?'':d.toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit',hour12:false});};
  const localDay=value=>{const d=value instanceof Date?value:new Date(value);return Number.isNaN(d.getTime())?'':d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');};
  function dayName(day){const t=new Date(),y=new Date(t);y.setDate(t.getDate()-1);if(day===localDay(t))return'今天';if(day===localDay(y))return'昨天';const d=new Date(day+'T00:00:00');return Number.isNaN(d.getTime())?day:d.toLocaleDateString('zh-CN',{month:'long',day:'numeric'});}
  function setSave(text,kind=''){ui.saveState.textContent=text;ui.saveState.className=kind;}
  function setStorage(ok,text){ui.storageDot.className='storage-dot '+(ok?'ready':'error');ui.storageState.textContent=text;}
  function showNotice(text,type='error',timeout=0){clearTimeout(noticeTimer);ui.notice.textContent=text;ui.notice.className='notice show '+(type==='info'?'info':'');if(timeout)noticeTimer=setTimeout(clearNotice,timeout);}
  function clearNotice(){clearTimeout(noticeTimer);ui.notice.className='notice';ui.notice.textContent='';}
  function closeSidebar(){ui.sidebar.classList.remove('open');ui.backdrop.classList.remove('show');}
  function openSidebar(){ui.sidebar.classList.add('open');ui.backdrop.classList.add('show');}
  function nearBottom(){return ui.chatScroll.scrollHeight-ui.chatScroll.scrollTop-ui.chatScroll.clientHeight<120;}
  function scrollBottom(){requestAnimationFrame(()=>{ui.chatScroll.scrollTop=ui.chatScroll.scrollHeight;});}

  function showDialog({title,text='',value=null,confirmText='确定',danger=false}){
    if(dialogResolve){dialogResolve(null);dialogResolve=null;}
    ui.dialogTitle.textContent=title;ui.dialogText.textContent=text;ui.dialogText.classList.toggle('hidden',!text);
    ui.dialogInput.classList.toggle('hidden',value===null);ui.dialogInput.value=value===null?'':value;
    ui.dialogConfirm.textContent=confirmText;ui.dialogConfirm.classList.toggle('danger',danger);ui.dialogMark.classList.toggle('danger',danger);
    ui.dialogMark.innerHTML=danger?'<svg viewBox="0 0 24 24"><path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5"/></svg>':'<svg viewBox="0 0 24 24"><path d="M4 16.5V20h3.5L18 9.5 14.5 6 4 16.5Z"/><path d="m12.8 7.7 3.5 3.5"/></svg>';
    ui.dialogBackdrop.classList.remove('hidden');ui.dialogBackdrop.setAttribute('aria-hidden','false');
    requestAnimationFrame(()=>ui.dialogBackdrop.classList.add('visible'));
    setTimeout(()=>value===null?ui.dialogConfirm.focus():(ui.dialogInput.focus(),ui.dialogInput.select()),90);
    return new Promise(resolve=>{dialogResolve=resolve;});
  }
  function closeDialog(value=null){if(!dialogResolve)return;const resolve=dialogResolve;dialogResolve=null;ui.dialogBackdrop.classList.remove('visible');ui.dialogBackdrop.setAttribute('aria-hidden','true');setTimeout(()=>ui.dialogBackdrop.classList.add('hidden'),220);resolve(value);}
  function cancelMessageEdit(clearText=false){editingMessageId='';ui.editStrip.classList.add('hidden');ui.composer.classList.remove('editing');if(clearText){ui.prompt.value='';pendingImages=[];renderAttachments();resizePrompt();}}
  function beginMessageEdit(message){
    if(generating){showNotice('请先停止当前回答，再编辑指令。','info',2600);return;}
    const index=current&&current.messages.findIndex(item=>item.id===message.id);if(index<0)return;
    const next=current.messages.slice(index+1).find(item=>item.role==='assistant');setComposeMode(next&&next.kind==='generated-image'?'image':'chat');
    editingMessageId=message.id;ui.prompt.value=message.content||'';pendingImages=Array.isArray(message.images)?message.images.map(item=>Object.assign({},item)):[];
    renderAttachments();resizePrompt();ui.editStrip.classList.remove('hidden');ui.composer.classList.add('editing');ui.prompt.focus();ui.prompt.setSelectionRange(ui.prompt.value.length,ui.prompt.value.length);scrollBottom();
  }

  async function storeFetch(path,options={}){
    const headers=Object.assign({'Authorization':'Bearer '+cfg.token},options.headers||{});
    if(options.body)headers['Content-Type']='application/json';
    const response=await fetch(cfg.storageUrl+path,Object.assign({},options,{headers,cache:'no-store'}));
    let data={};try{data=await response.json();}catch{}
    if(!response.ok){const error=new Error(data.error||('本地服务返回 '+response.status));error.status=response.status;throw error;}
    return data;
  }
  function summaryFromChat(chat){return{id:chat.id,title:chat.title,createdAt:chat.createdAt,updatedAt:chat.updatedAt,date:localDay(chat.createdAt),messageCount:chat.messages.length,revision:chat.revision};}
  function mergeSummary(chat){const item=summaryFromChat(chat),i=histories.findIndex(x=>x.id===chat.id);if(i>=0)histories[i]=item;else histories.push(item);histories.sort((a,b)=>String(b.updatedAt).localeCompare(String(a.updatedAt)));renderHistory();}
  const snapshot=chat=>JSON.parse(JSON.stringify(chat));
  function persistCurrent(){
    clearTimeout(saveTimer);saveTimer=null;const chatId=current&&current.id;if(!chatId)return Promise.resolve(null);
    const run=saveChain.catch(()=>{}).then(async()=>{
      if(!current||current.id!==chatId)return null;if(storageLocked)throw new Error('当前聊天已锁定，请刷新页面后继续。');
      setSave('正在写入 U 盘…','saving');const payload=snapshot(current);let data;
      try{data=await storeFetch('/api/chats',{method:'POST',body:JSON.stringify(payload)});}
      catch(error){if(error.status===409){storageLocked=true;if(aborter)aborter.abort();showNotice('这段聊天已在另一个窗口修改。为防止覆盖，已停止写入。');}else showNotice('保存失败：'+error.message);setSave('保存失败，请勿关闭页面','error');setStorage(false,'U 盘存档失败');throw error;}
      if(current&&current.id===chatId){current.revision=data.chat.revision;lastSavedPath=data.path||lastSavedPath;mergeSummary(current);}
      setStorage(true,'内容已保存在 U 盘');setSave('已保存到 U 盘','saved');return data;
    });saveChain=run;return run;
  }
  function scheduleSave(){clearTimeout(saveTimer);saveTimer=setTimeout(()=>persistCurrent().catch(()=>{}),900);}
  async function flushSave(){clearTimeout(saveTimer);saveTimer=null;if(current)await persistCurrent();await saveChain.catch(error=>{throw error;});}
  async function refreshState(render=true){const state=await storeFetch('/api/state');histories=Array.isArray(state.chats)?state.chats:[];ui.storagePath.textContent=escapePath(state.storageRoot||cfg.storageRoot);lastSavedPath=state.storageRoot||lastSavedPath;setStorage(true,state.unreadableChats?'部分旧记录无法读取':'内容已保存在 U 盘');if(state.unreadableChats)showNotice('发现 '+state.unreadableChats+' 段损坏记录，原文件已保留。');if(render)renderHistory();return state;}
  function renderHistory(){
    ui.historyList.replaceChildren();if(!histories.length){const empty=document.createElement('div');empty.className='history-empty';empty.textContent='还没有记录。第一段对话会按日期保存在 U 盘里。';ui.historyList.append(empty);return;}
    let lastDay='';for(const item of histories){if(item.date!==lastDay){lastDay=item.date;const label=document.createElement('div');label.className='date-label';label.textContent=dayName(lastDay);ui.historyList.append(label);}
      const row=document.createElement('div');row.className='history-row'+(current&&current.id===item.id?' active':'');
      const button=document.createElement('button');button.className='history-item';button.dataset.id=item.id;const title=document.createElement('strong');title.textContent=item.title||'新对话';const meta=document.createElement('span');meta.textContent=shortTime(item.updatedAt)+' · '+(item.messageCount||0)+' 条';button.append(title,meta);button.addEventListener('click',()=>openChat(item.id));
      const actions=document.createElement('div');actions.className='history-actions';
      const rename=document.createElement('button');rename.type='button';rename.title='重命名';rename.setAttribute('aria-label','重命名 '+(item.title||'新对话'));rename.innerHTML='<svg viewBox="0 0 24 24"><path d="M4 16.5V20h3.5L18 9.5 14.5 6 4 16.5Z"/><path d="m12.8 7.7 3.5 3.5"/></svg>';rename.addEventListener('click',event=>{event.stopPropagation();renameChat(item);});
      const remove=document.createElement('button');remove.type='button';remove.className='delete';remove.title='删除';remove.setAttribute('aria-label','删除 '+(item.title||'新对话'));remove.innerHTML='<svg viewBox="0 0 24 24"><path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5"/></svg>';remove.addEventListener('click',event=>{event.stopPropagation();deleteChat(item);});
      actions.append(rename,remove);row.append(button,actions);ui.historyList.append(row);
    }
  }
  async function renameChat(item){
    if(generating){showNotice('请先停止当前任务，再修改名称。','info',2600);return;}
    const value=await showDialog({title:'重命名对话',text:'换一个更容易找到的名称。',value:item.title||'新对话',confirmText:'保存'});const title=String(value||'').trim();if(!title)return;
    try{let chat;if(current&&current.id===item.id){await flushSave();chat=current;}else chat=(await storeFetch('/api/chats/'+encodeURIComponent(item.id))).chat;chat.title=title.slice(0,100);const data=await storeFetch('/api/chats',{method:'POST',body:JSON.stringify(chat)});if(current&&current.id===item.id){current=data.chat;ui.chatTitle.textContent=current.title;}await refreshState();showNotice('对话名称已保存。','info',1800);}catch(error){showNotice('重命名失败：'+error.message);}
  }
  async function deleteChat(item){
    if(generating){showNotice('请先停止当前任务，再删除记录。','info',2600);return;}
    const confirmed=await showDialog({title:'删除这段对话？',text:'“'+(item.title||'新对话')+'”及其中的文字和图片记录会从 U 盘删除。',confirmText:'删除',danger:true});if(!confirmed)return;
    try{const deletingCurrent=current&&current.id===item.id;if(deletingCurrent)await flushSave();await storeFetch('/api/chats/'+encodeURIComponent(item.id),{method:'DELETE'});if(deletingCurrent){current=null;cancelMessageEdit(true);}await refreshState();if(deletingCurrent){if(histories.length)await openChat(histories[0].id);else await createChat(false);}showNotice('对话已删除。','info',1800);}catch(error){showNotice('删除失败：'+error.message);}
  }
  async function openChat(id){if(generating){showNotice('请先停止当前任务，再切换记录。','info',3000);return;}closeSidebar();clearNotice();try{if(current)await flushSave();const data=await storeFetch('/api/chats/'+encodeURIComponent(id));current=data.chat;lastSavedPath=data.path||lastSavedPath;storageLocked=false;cancelMessageEdit(true);renderConversation(true);renderHistory();}catch(error){showNotice('打开记录失败：'+error.message);}}
  async function createChat(focus=true){if(generating){showNotice('请先停止当前任务，再新建对话。','info',3000);return;}clearNotice();try{if(current)await flushSave();}catch{return;}const now=isoNow();current={schemaVersion:2,id:uuid(),title:'新对话',createdAt:now,updatedAt:now,revision:0,messages:[],model:modelId};storageLocked=false;cancelMessageEdit(true);setComposeMode('chat');renderConversation(true);try{await persistCurrent();}catch{return;}if(focus)ui.prompt.focus();}
  function renderConversation(animate=false){const messages=current&&Array.isArray(current.messages)?current.messages.filter(m=>m.role!=='system'):[];ui.chatTitle.textContent=current&&current.title?current.title:'新对话';ui.welcome.classList.toggle('hidden',messages.length>0);ui.messages.replaceChildren();for(const message of messages)ui.messages.append(renderMessage(message));ui.messages.classList.remove('conversation-enter');if(animate){void ui.messages.offsetWidth;ui.messages.classList.add('conversation-enter');}scrollBottom();}
  function renderMessage(message){
    const article=document.createElement('article');article.className='message '+message.role;article.dataset.messageId=message.id;
    if(message.role==='assistant'){const avatar=document.createElement('div');avatar.className='message-avatar';avatar.textContent='浮';article.append(avatar);}
    const body=document.createElement('div');body.className='message-body';const label=document.createElement('div');label.className='message-label';label.textContent=message.role==='assistant'?'离线助手':'我';if(message.editedAt){const edited=document.createElement('span');edited.className='edited-badge';edited.textContent='已编辑';label.append(edited);}body.append(label);
    const images=Array.isArray(message.images)?message.images.filter(x=>x&&x.dataUrl):[];
    if(images.length){const gallery=document.createElement('div');gallery.className='message-images';for(const item of images){const frame=document.createElement('div');frame.className='message-image';const img=document.createElement('img');img.src=item.dataUrl;img.alt=item.name||'图片';img.loading='lazy';frame.append(img);gallery.append(frame);}body.append(gallery);}
    const content=document.createElement('div');content.className='message-content';
    if(message.role==='assistant'&&!message.content){if(message.kind==='generated-image'){const progress=document.createElement('span');progress.className='generation-progress';const spinner=document.createElement('i');const text=document.createElement('span');text.textContent='正在本地生成画面，首次加载会慢一些…';progress.append(spinner,text);content.append(progress);}else{const typing=document.createElement('span');typing.className='typing';typing.append(document.createElement('i'),document.createElement('i'),document.createElement('i'));content.append(typing);}}
    else if(message.role==='assistant')renderMarkdown(content,message.content||'');else content.textContent=message.content||'';
    body.append(content);
    if(message.meta&&message.kind==='generated-image'){const meta=document.createElement('div');meta.className='image-meta';if(message.meta.model){const model=document.createElement('span');model.textContent=message.meta.model;meta.append(model);}if(message.meta.width){const size=document.createElement('span');size.textContent=message.meta.width+'×'+(message.meta.height||message.meta.width);meta.append(size);}if(message.meta.seed!==undefined){const seed=document.createElement('span');seed.textContent='种子 '+message.meta.seed;meta.append(seed);}if(message.meta.elapsedSeconds){const elapsed=document.createElement('span');elapsed.textContent=message.meta.elapsedSeconds+' 秒';meta.append(elapsed);}body.append(meta);}
    if(message.role==='user'){const tools=document.createElement('div');tools.className='message-tools user-message-tools';if(message.editedAt){const edited=document.createElement('span');edited.className='edited-note';edited.textContent='已编辑';tools.append(edited);}const edit=document.createElement('button');edit.className='edit-message';edit.textContent='编辑重发';edit.addEventListener('click',()=>beginMessageEdit(message));tools.append(edit);body.append(tools);}
    if(message.role==='assistant'&&(message.content||images.length)){const tools=document.createElement('div');tools.className='message-tools';if(message.content){const copy=document.createElement('button');copy.className='copy-answer';copy.textContent='复制文字';copy.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(message.content);copy.textContent='已复制';setTimeout(()=>copy.textContent='复制文字',1400);}catch{showNotice('复制失败，请手动选择文字。','info',2500);}});tools.append(copy);}if(images.length){const save=document.createElement('button');save.className='open-image';save.textContent='保存图片';save.addEventListener('click',()=>{const link=document.createElement('a');link.href=images[0].dataUrl;link.download=images[0].name||'离线生成.png';link.click();});tools.append(save);}body.append(tools);}
    article.append(body);return article;
  }
  function appendInline(parent,text){const regex=/(\*\*[^*]+\*\*|\x60[^\x60]+\x60)/g;let index=0,match;while((match=regex.exec(text))){if(match.index>index)parent.append(document.createTextNode(text.slice(index,match.index)));const token=match[0],el=document.createElement(token.startsWith('**')?'strong':'code');el.textContent=token.startsWith('**')?token.slice(2,-2):token.slice(1,-1);parent.append(el);index=match.index+token.length;}if(index<text.length)parent.append(document.createTextNode(text.slice(index)));}
  function renderMarkdown(root,text){const lines=String(text).replace(/\r/g,'').split('\n');let paragraph=[],list=null,code=null;const flush=()=>{if(!paragraph.length)return;const p=document.createElement('p');paragraph.forEach((line,i)=>{if(i)p.append(document.createElement('br'));appendInline(p,line);});root.append(p);paragraph=[];};const close=()=>{list=null;};for(const line of lines){if(code){if(/^\x60\x60\x60/.test(line)){root.append(code.pre);code=null;}else code.node.textContent+=(code.node.textContent?'\n':'')+line;continue;}if(/^\x60\x60\x60/.test(line)){flush();close();const pre=document.createElement('pre'),node=document.createElement('code');pre.append(node);code={pre,node};continue;}if(!line.trim()){flush();close();continue;}const heading=line.match(/^(#{1,3})\s+(.+)/);if(heading){flush();close();const h=document.createElement('h'+heading[1].length);appendInline(h,heading[2]);root.append(h);continue;}const bullet=line.match(/^\s*[-*]\s+(.+)/),number=line.match(/^\s*\d+[.)]\s+(.+)/);if(bullet||number){flush();const kind=bullet?'ul':'ol';if(!list||list.tagName.toLowerCase()!==kind){list=document.createElement(kind);root.append(list);}const li=document.createElement('li');appendInline(li,(bullet||number)[1]);list.append(li);continue;}const quote=line.match(/^>\s?(.*)/);if(quote){flush();close();const b=document.createElement('blockquote');appendInline(b,quote[1]);root.append(b);continue;}close();paragraph.push(line);}if(code)root.append(code.pre);flush();}
  function updateLastAssistant(message){const keepBottom=nearBottom(),node=ui.messages.querySelector('[data-message-id="'+CSS.escape(message.id)+'"]');if(!node)return;const fresh=renderMessage(message);fresh.classList.add('stream-update');node.replaceWith(fresh);if(keepBottom)scrollBottom();}
  function autoTitle(text,kind){const prefix=kind==='generated-image'?'画：':'';const clean=text.replace(/\s+/g,' ').trim();return prefix+(clean.length>22?clean.slice(0,22)+'…':(clean||'新对话'));}
  function modelMessages(){
    const rows=[];
    for(let i=0;i<current.messages.length;i++){
      const message=current.messages[i],next=current.messages[i+1];
      if(!['user','assistant'].includes(message.role)||!message.content)continue;
      if(message.kind==='generated-image'||(message.role==='user'&&next&&next.role==='assistant'&&next.kind==='generated-image'))continue;
      const clean={role:message.role,content:String(message.content),images:message.role==='user'&&Array.isArray(message.images)?message.images:[]};
      const previous=rows[rows.length-1];
      if(previous&&previous.role===clean.role){previous.content+='\n\n'+clean.content;if(clean.images.length)previous.images=clean.images;}
      else rows.push(clean);
    }
    while(rows.length&&rows[0].role!=='user')rows.shift();
    const budget=5000;let used=0,selected=[];
    for(let i=rows.length-1;i>=0&&used<budget;i--){const message=rows[i],remaining=budget-used,text=message.content.length>remaining?message.content.slice(-remaining):message.content;selected.unshift({role:message.role,content:text,images:message.images});used+=text.length;}
    while(selected.length&&selected[0].role!=='user')selected.shift();
    const out=selected.map(message=>{let content=message.content;if(message.role==='user'&&message.images.length){content=[{type:'text',text:message.content||'请描述这张图片。'},...message.images.slice(0,1).filter(x=>x.dataUrl).map(x=>({type:'image_url',image_url:{url:x.dataUrl}}))];}return{role:message.role,content};});
    out.unshift({role:'system',content:'你是一位可靠、自然、耐心的中文助手。默认使用简体中文，先给出明确回答，再补充必要说明。你在本机离线运行，无法访问互联网。看到图片时，应基于画面如实回答，不确定的细节要说明。'});return out;
  }
  async function streamChat(assistant){
    const response=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},signal:aborter.signal,body:JSON.stringify({model:modelId,messages:modelMessages(),stream:true,max_tokens:1536,temperature:.65,top_p:.9})});
    if(!response.ok){let detail='';try{detail=(await response.json()).error?.message||'';}catch{}throw new Error(detail||('模型返回 '+response.status));}
    if(!response.body)throw new Error('浏览器不支持流式回答。');const reader=response.body.getReader(),decoder=new TextDecoder(),pending={text:''};let pulse=0;
    while(true){const part=await reader.read();if(part.done)break;pending.text+=decoder.decode(part.value,{stream:true});const lines=pending.text.split('\n');pending.text=lines.pop()||'';for(const raw of lines){const line=raw.trim();if(!line.startsWith('data:'))continue;const data=line.slice(5).trim();if(!data||data==='[DONE]')continue;let json;try{json=JSON.parse(data);}catch{continue;}const delta=json.choices&&json.choices[0]&&json.choices[0].delta;if(delta&&typeof delta.content==='string'){assistant.content+=delta.content;current.updatedAt=isoNow();updateLastAssistant(assistant);if(Date.now()-pulse>1100){pulse=Date.now();scheduleSave();}}}}
    if(!assistant.content)assistant.content='模型没有返回文字，请换一种问法再试。';
  }
  async function improveImagePrompt(text){
    try{const response=await fetch('/v1/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},signal:aborter.signal,body:JSON.stringify({model:modelId,messages:[{role:'system',content:'Convert the user image description into one concise, vivid English SDXL prompt. Preserve every requested subject, composition, color, style and mood. Output only the English prompt, without quotes or explanation.'},{role:'user',content:text}],stream:false,max_tokens:180,temperature:.35})});if(!response.ok)return text;const data=await response.json(),value=String(data.choices?.[0]?.message?.content||'').trim();return value||text;}catch(error){if(error.name==='AbortError')throw error;return text;}
  }
  async function generateImage(assistant,originalPrompt){
    assistant.content='正在理解中文描述并整理画面…';updateLastAssistant(assistant);const prompt=await improveImagePrompt(originalPrompt);assistant.content='';updateLastAssistant(assistant);
    const size=Number(cfg.imageSize)||512,steps=Number(cfg.imageSteps)||1;const data=await storeFetch('/api/images',{method:'POST',signal:aborter.signal,body:JSON.stringify({prompt,originalPrompt,steps,width:size,height:size,seed:-1})});
    assistant.content='已在本地生成这张图片。';assistant.images=[{name:data.fileName||'离线生成.png',type:'image/png',dataUrl:data.dataUrl,path:data.path||''}];assistant.meta={seed:data.seed,elapsedSeconds:data.elapsedSeconds,englishPrompt:prompt,model:data.model||cfg.imageModel||'',width:data.width||size,height:data.height||size,steps:data.steps||steps};updateLastAssistant(assistant);
  }
  async function sendMessage(prefill){
    if(generating)return;const text=(typeof prefill==='string'?prefill:ui.prompt.value).trim();if(!text){showNotice(composeMode==='image'?'先描述你想生成的画面。':'请输入内容。','info',2200);return;}clearNotice();if(!current)await createChat(false);if(!current||storageLocked)return;
    const images=composeMode==='chat'?pendingImages.map(x=>Object.assign({},x)):[];const kind=composeMode==='image'?'generated-image':'chat';let user;
    if(editingMessageId){const index=current.messages.findIndex(message=>message.id===editingMessageId&&message.role==='user');if(index<0){cancelMessageEdit();showNotice('原指令已经不存在，请重新发送。');return;}user=current.messages[index];user.content=text;user.editedAt=isoNow();if(images.length)user.images=images;else delete user.images;current.messages=current.messages.slice(0,index+1);editingMessageId='';ui.editStrip.classList.add('hidden');ui.composer.classList.remove('editing');if(current.messages.filter(m=>m.role==='user').length===1)current.title=autoTitle(text,kind);}else{user={id:uuid(),role:'user',content:text,createdAt:isoNow()};if(images.length)user.images=images;current.messages.push(user);if(current.messages.filter(m=>m.role==='user').length===1)current.title=autoTitle(text,kind);}
    current.updatedAt=isoNow();ui.prompt.value='';pendingImages=[];renderAttachments();resizePrompt();renderConversation();const userNode=ui.messages.querySelector('[data-message-id="'+CSS.escape(user.id)+'"]');if(userNode)userNode.classList.add('message-enter');try{await persistCurrent();}catch{return;}
    const assistant={id:uuid(),role:'assistant',content:'',createdAt:isoNow(),model:modelId,kind};current.messages.push(assistant);current.updatedAt=isoNow();renderConversation();const assistantNode=ui.messages.querySelector('[data-message-id="'+CSS.escape(assistant.id)+'"]');if(assistantNode)assistantNode.classList.add('message-enter');generating=true;generatingKind=kind;aborter=new AbortController();updateControls();
    try{if(kind==='generated-image')await generateImage(assistant,text);else await streamChat(assistant);}
    catch(error){if(error.name==='AbortError'){if(!assistant.content&&!assistant.images){const index=current.messages.findIndex(m=>m.id===assistant.id);if(index>=0)current.messages.splice(index,1);}else assistant.content+=(assistant.content?'\n\n':'')+'（已停止）';}else{assistant.content='任务失败：'+error.message;showNotice((kind==='generated-image'?'生图':'回答')+'失败：'+error.message);}}
    finally{generating=false;generatingKind='';aborter=null;current.updatedAt=isoNow();renderConversation();updateControls();try{await persistCurrent();}catch{}ui.prompt.focus();}
  }
  function updateControls(){ui.send.classList.toggle('hidden',generating);ui.stop.classList.toggle('hidden',!generating);ui.prompt.disabled=generating;ui.newChat.disabled=generating;ui.attachImage.disabled=generating||composeMode==='image';ui.imageMode.disabled=generating;}
  function resizePrompt(){ui.prompt.style.height='auto';ui.prompt.style.height=Math.min(ui.prompt.scrollHeight,150)+'px';}
  function setComposeMode(mode){if(generating)return;const next=mode==='image'?'image':'chat',changed=next!==composeMode;composeMode=next;const active=composeMode==='image';ui.composer.classList.toggle('image-active',active);if(changed){ui.composer.classList.remove('mode-transition');void ui.composer.offsetWidth;ui.composer.classList.add('mode-transition');setTimeout(()=>ui.composer.classList.remove('mode-transition'),420);}ui.imageMode.classList.toggle('active',active);ui.imageMode.setAttribute('aria-pressed',String(active));ui.send.querySelector('span').textContent=active?'生成':'发送';ui.prompt.placeholder=active?'描述你想生成的画面，例如：雨夜霓虹下的白猫，电影感':'输入消息，或上传图片后提问';ui.modeHint.textContent=active?(cfg.imageModel||'离线生图')+' · 首张会加载模型，之后更快':'Enter 发送 · Shift + Enter 换行';if(active){pendingImages=[];renderAttachments();}updateControls();ui.prompt.focus();}
  async function fileToImage(file){if(!file||!/^image\/(png|jpeg|webp)$/.test(file.type))throw new Error('请选择 PNG、JPG 或 WebP 图片。');if(file.size>16*1024*1024)throw new Error('图片不能超过 16MB。');const url=URL.createObjectURL(file);try{const image=await new Promise((resolve,reject)=>{const node=new Image();node.onload=()=>resolve(node);node.onerror=()=>reject(new Error('图片无法读取。'));node.src=url;});const max=1280,scale=Math.min(1,max/Math.max(image.naturalWidth,image.naturalHeight)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(image.naturalWidth*scale));canvas.height=Math.max(1,Math.round(image.naturalHeight*scale));const ctx=canvas.getContext('2d',{alpha:false});ctx.fillStyle='#ffffff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(image,0,0,canvas.width,canvas.height);return{name:(file.name||'上传图片').replace(/[^\w\-.\u4e00-\u9fff]/g,'_'),type:'image/jpeg',dataUrl:canvas.toDataURL('image/jpeg',.86)};}finally{URL.revokeObjectURL(url);}}
  function renderAttachments(){ui.attachmentStrip.replaceChildren();ui.attachmentStrip.classList.toggle('hidden',!pendingImages.length);for(const item of pendingImages){const card=document.createElement('div');card.className='attachment-card';const img=document.createElement('img');img.src=item.dataUrl;img.alt='待识别图片';const remove=document.createElement('button');remove.className='remove-attachment';remove.textContent='×';remove.title='移除图片';remove.addEventListener('click',()=>{pendingImages=[];renderAttachments();});card.append(img,remove);ui.attachmentStrip.append(card);}}
  async function chooseImage(file){try{const image=await fileToImage(file);setComposeMode('chat');pendingImages=[image];renderAttachments();if(!ui.prompt.value.trim())ui.prompt.placeholder='问问这张图片，例如：图里有什么？';ui.prompt.focus();}catch(error){showNotice(error.message);}finally{ui.imageInput.value='';}}
  async function loadModel(){const response=await fetch('/v1/models',{cache:'no-store'});if(!response.ok)throw new Error('无法读取模型');const data=await response.json(),ids=(data.data||[]).map(x=>x.id);if(!ids.length)throw new Error('没有找到已加载的模型');if(!modelId||!ids.includes(modelId))modelId=ids[0];ui.modelLabel.textContent='Gemma 3 4B · '+(cfg.hardwareProfile||'聊天与识图');}
  async function copyStoragePath(){try{await navigator.clipboard.writeText(lastSavedPath||cfg.storageRoot);showNotice('存档路径已复制。','info',1800);}catch{showNotice('存档位置：'+(lastSavedPath||cfg.storageRoot),'info',4000);}}
  async function cancelCurrent(){if(!generating)return;if(generatingKind==='generated-image')storeFetch('/api/images/cancel',{method:'POST',body:'{}'}).catch(()=>{});if(aborter)aborter.abort();}
  async function initialize(){if(!cfg.storageUrl||!cfg.token){setStorage(false,'启动配置缺失');showNotice('请从 U 盘启动，不要单独打开网页文件。');return;}ui.storagePath.textContent=escapePath(cfg.storageRoot);try{await loadModel();}catch(error){ui.modelLabel.textContent='模型连接失败';showNotice(error.message);}try{if(window.cleanupLegacyUi)await window.cleanupLegacyUi();if(window.importLegacyChats){const result=await window.importLegacyChats(cfg);if(result&&result.imported)showNotice('已迁移 '+result.imported+' 段旧聊天。','info',5000);}await refreshState();if(histories.length)await openChat(histories[0].id);else await createChat(false);}catch(error){setStorage(false,'无法连接 U 盘存档');setSave('存档未连接','error');showNotice('存档服务连接失败：'+error.message);}ui.prompt.focus();}
  function watchLocalServer(){let failures=0,busy=false;setInterval(async()=>{if(busy)return;busy=true;const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),1800);try{const response=await fetch('/health',{cache:'no-store',signal:controller.signal});if(!response.ok)throw new Error();failures=0;}catch{failures++;if(failures>=3)window.close();}finally{clearTimeout(timer);busy=false;}},2200);}

  ui.newChat.addEventListener('click',()=>createChat());ui.refreshHistory.addEventListener('click',()=>refreshState().catch(error=>showNotice('刷新失败：'+error.message)));ui.send.addEventListener('click',()=>sendMessage());ui.stop.addEventListener('click',cancelCurrent);ui.copyPath.addEventListener('click',copyStoragePath);ui.cancelEdit.addEventListener('click',()=>{cancelMessageEdit(true);ui.prompt.focus();});
  ui.prompt.addEventListener('input',resizePrompt);ui.prompt.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing){event.preventDefault();sendMessage();}});
  ui.attachImage.addEventListener('click',()=>ui.imageInput.click());ui.imageInput.addEventListener('change',()=>chooseImage(ui.imageInput.files&&ui.imageInput.files[0]));ui.imageMode.addEventListener('click',()=>setComposeMode(composeMode==='image'?'chat':'image'));ui.welcomeVision.addEventListener('click',()=>ui.imageInput.click());ui.welcomeImage.addEventListener('click',()=>setComposeMode('image'));
  document.querySelectorAll('[data-prompt]').forEach(button=>button.addEventListener('click',()=>{setComposeMode('chat');ui.prompt.value=button.dataset.prompt;resizePrompt();ui.prompt.focus();}));
  ui.openSidebar.addEventListener('click',openSidebar);ui.closeSidebar.addEventListener('click',closeSidebar);ui.backdrop.addEventListener('click',closeSidebar);
  ui.dialogCancel.addEventListener('click',()=>closeDialog(null));ui.dialogConfirm.addEventListener('click',()=>closeDialog(ui.dialogInput.classList.contains('hidden')?true:ui.dialogInput.value));ui.dialogBackdrop.addEventListener('mousedown',event=>{if(event.target===ui.dialogBackdrop)closeDialog(null);});ui.dialogInput.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();closeDialog(ui.dialogInput.value);}});
  ui.composerWrap.addEventListener('wheel',event=>{if(event.ctrlKey||!event.deltaY)return;ui.chatScroll.scrollTop+=event.deltaY;event.preventDefault();},{passive:false});
  window.addEventListener('keydown',event=>{if(event.key==='Escape'&&dialogResolve){event.preventDefault();closeDialog(null);return;}if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='n'){event.preventDefault();createChat();}});
  window.addEventListener('beforeunload',event=>{if(generating||saveTimer){event.preventDefault();event.returnValue='任务正在生成或保存，确定关闭吗？';}});
  watchLocalServer();initialize();
})();
