// One durable snapshot atomically includes records, cursor, outbox, and conflicts.
export const empty = () => ({records:{},remote:{},cursor:0,outbox:[],conflicts:{},cache:{}});
export function openStore(name){return new Promise((resolve,reject)=>{const r=indexedDB.open(name,2);r.onupgradeneeded=()=>{for(const key of ['state','transfers','file_cache'])if(!r.result.objectStoreNames.contains(key))r.result.createObjectStore(key);};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
export function read(db){return new Promise((resolve,reject)=>{const t=db.transaction('state');const r=t.objectStore('state').get('library');r.onsuccess=()=>resolve(r.result||empty());r.onerror=()=>reject(r.error);});}
export function persist(db,state){return new Promise((resolve,reject)=>{const t=db.transaction('state','readwrite');t.objectStore('state').put(state,'library');t.oncomplete=resolve;t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error);});}
export function enqueue(state,item,previous){
 const now=new Date().toISOString();item=structuredClone(item);
 if(previous){item.body.createdAt=previous.body.createdAt||'';}else item.body.createdAt=now;
 item.body.updatedAt=now;
 if(item.kind==='tasks'){
  const status=item.body.status||'To do';item.body.archived=String(status==='Done');
  if(!previous||status!==(previous.body.status||'To do')){
   const history=JSON.parse(previous?.body.taskAudit||'[]');history.push({id:crypto.randomUUID(),date:(Date.now()/1000)-978307200,from:previous?.body.status||null,status});
   item.body.taskAudit=JSON.stringify(history);if(!previous)item.body.taskCreatedAt=now;
  }
 }
 state.records[item.id]=item;if(state.conflicts[item.id])state.conflicts[item.id].local=structuredClone(item);
 state.outbox.push({operationID:crypto.randomUUID(),id:item.id,kind:item.kind,body:item.body,deleted:item.deleted||false});return item;
}
export function acceptPull(state,page){for(const row of page.changes){(state.remote??={})[row.id]=row;if(!state.outbox.some(m=>m.id===row.id)&&!state.conflicts[row.id])state.records[row.id]=row;}state.cursor=page.cursor;}

export function getValue(db,store,key){return new Promise((resolve,reject)=>{const r=db.transaction(store).objectStore(store).get(key);r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
export function putValue(db,store,key,value){return new Promise((resolve,reject)=>{const t=db.transaction(store,'readwrite');t.objectStore(store).put(value,key);t.oncomplete=resolve;t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error);});}
export function deleteValue(db,store,key){return new Promise((resolve,reject)=>{const t=db.transaction(store,'readwrite');t.objectStore(store).delete(key);t.oncomplete=resolve;t.onerror=()=>reject(t.error);});}
export function allValues(db,store){return new Promise((resolve,reject)=>{const r=db.transaction(store).objectStore(store).getAll();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
export function clearStore(db,store){return new Promise((resolve,reject)=>{const t=db.transaction(store,'readwrite');t.objectStore(store).clear();t.oncomplete=resolve;t.onerror=()=>reject(t.error);});}
