import {mkdir,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {makeFixture,compare,makeEvidence,PRESETS} from '../../priv/static/js/energyflex-model.js';
const dir=resolve(process.argv[2]||'/tmp/energyflex-evidence');
await mkdir(dir,{recursive:true});
for(const p of PRESETS){const f=makeFixture(p.id);await writeFile(join(dir,`${p.id}.evidence.json`),JSON.stringify(await makeEvidence(f,compare(f)),null,2)+'\n');}
console.log(dir);
