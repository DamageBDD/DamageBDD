import {mkdir,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {webcrypto} from 'node:crypto';
import {SCENARIOS,runScenario,evidence} from '../../priv/static/js/payment-guard-model.js';
const directory=resolve(process.argv[2]||'/tmp/payment-guard-evidence');await mkdir(directory,{recursive:true});
for(const s of SCENARIOS)await writeFile(resolve(directory,`${s.id}.evidence.json`),JSON.stringify(await evidence(runScenario(s.id),webcrypto.subtle),null,2)+'\n');
console.log(directory);
