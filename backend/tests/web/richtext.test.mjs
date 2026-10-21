import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {test} from 'node:test';
const source=await readFile(new URL('../../app/web/richtext.js',import.meta.url),'utf8');
const {rtfToHTML}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
test('RTF text, Unicode and scoped formatting render safely',()=>{const html=rtfToHTML(btoa('{\\rtf1\\ansi {\\fonttbl{\\f0 Arial;}}Plain {\\b bold} \\u1513? <script>\\par next}'));assert.ok(html.includes('font-weight:bold'));assert.ok(html.includes('ש'));assert.ok(!html.includes('<script>'));assert.ok(!html.includes('Arial'));assert.ok(html.includes('<br>'));});
test('unrecognized or missing RTF falls back to escaped text',()=>{assert.equal(rtfToHTML('', '<unsafe>'), '&lt;unsafe&gt;');});
