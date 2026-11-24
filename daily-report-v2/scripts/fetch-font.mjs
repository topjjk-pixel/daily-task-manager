import fs from 'node:fs/promises';import crypto from 'node:crypto';
const path=new URL('../public/fonts/NanumGothic-Regular.ttf',import.meta.url);
const expected='76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31';let data;try{data=await fs.readFile(path);}catch{}
if(!data){const r=await fetch('https://raw.githubusercontent.com/google/fonts/main/ofl/nanumgothic/NanumGothic-Regular.ttf',{signal:AbortSignal.timeout(60000)});if(!r.ok)throw Error('Korean PDF font download failed: '+r.status);data=Buffer.from(await r.arrayBuffer());}
if(crypto.createHash('sha256').update(data).digest('hex')!==expected)throw Error('Korean PDF font integrity check failed');
await fs.mkdir(new URL('../public/fonts/',import.meta.url),{recursive:true});await fs.writeFile(path,data);console.log('Korean PDF font integrity verified');
