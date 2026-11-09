import {mkdir,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {runScenario,makeEvidence,SCENARIOS} from '../../priv/static/js/food-rescue-model.js';
const output=process.argv[2];if(!output)throw new Error('Usage: node export_fixtures.mjs OUTPUT_DIRECTORY');
await mkdir(output,{recursive:true});
for(const {id} of SCENARIOS)await writeFile(join(output,`${id}.evidence.json`),JSON.stringify(await makeEvidence(runScenario(id)),null,2)+'\n');
