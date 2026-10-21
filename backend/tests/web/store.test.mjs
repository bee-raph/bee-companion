import {readFile} from 'node:fs/promises';
import {webcrypto} from 'node:crypto';
import assert from 'node:assert/strict';
import {test} from 'node:test';
globalThis.crypto ??= webcrypto;
const source=await readFile(new URL('../../app/web/store.js',import.meta.url),'utf8');
const {empty,enqueue,acceptPull}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
test('offline edits retain snapshots and task history',()=>{
 const s=empty(),r={id:'task',kind:'tasks',revision:0,body:{title:'One',status:'To do'}};
 enqueue(s,r);const old=structuredClone(s.records.task),next=structuredClone(old);next.body.status='Done';enqueue(s,next,old);
 assert.equal(s.outbox.length,2);assert.equal(s.outbox[0].body.status,'To do');assert.equal(s.outbox[1].body.status,'Done');assert.equal(s.records.task.body.archived,'true');assert.equal(JSON.parse(s.records.task.body.taskAudit).length,2);
});
test('pull advances cursor without overwriting local drafts or conflicts',()=>{
 const s=empty();enqueue(s,{id:'a',kind:'notes',revision:0,body:{title:'local'}});s.conflicts.b={local:{body:{title:'local conflict'}}};
 acceptPull(s,{cursor:10,changes:[{id:'a',body:{title:'remote'}},{id:'b',body:{title:'remote'}},{id:'c',body:{title:'new'}}]});
 assert.equal(s.cursor,10);assert.equal(s.records.a.body.title,'local');assert.equal(s.records.b,undefined);assert.equal(s.records.c.body.title,'new');
});
test('editing a conflicted draft keeps the latest version for resolution',()=>{const s=empty();s.conflicts.a={local:{}};enqueue(s,{id:'a',kind:'notes',body:{title:'latest'}});assert.equal(s.conflicts.a.local.body.title,'latest');});
