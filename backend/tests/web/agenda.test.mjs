import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {test} from 'node:test';
const source=await readFile(new URL('../../app/web/agenda.js',import.meta.url),'utf8');
const {agendaDays,layoutEvents}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
test('month and week include local calendar days',()=>{const date=new Date(2026,9,21);assert.equal(agendaDays(date,'Month').length,42);assert.equal(agendaDays(date,'Week').length,7);assert.equal(agendaDays(date,'Day')[0].getDate(),21);});
test('overlapping events get columns and separate groups reuse full width',()=>{const date=new Date(2026,9,21);const records=[0,10,60].map((m,i)=>({id:String(i),body:{date:new Date(2026,9,21,9,m).toISOString()}}));const result=layoutEvents(records,date);assert.deepEqual(result.map(x=>[x.column,x.columns]),[[0,2],[1,2],[0,1]]);});
