#!/usr/bin/env node
/**
 * OTV-001 portable replay verifier. Only verifies synthetic model invariants,
 * same-version generator replay and SHA-256 integrity; makes no flight claim.
 * Usage: node apps/ecai/tools/verify_otv_evidence.mjs OTV-001-*.evidence.json
 */
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {isDeepStrictEqual} from 'node:util';
import {simulateTransfer,evaluateTransfer,OTV_VERSION} from '../priv/static/js/ecai-orbital-model.js';

export function verifyEvidence(doc){
  if(!doc||typeof doc!=='object'||typeof doc.sha256!=='string')throw new Error('Missing evidence digest');
  const {sha256,...content}=doc;
  const hash=createHash('sha256').update(JSON.stringify(content)).digest('hex');
  if(hash!==sha256)throw new Error('SHA-256 mismatch: evidence payload has changed');
  if(content.schema!=='otv-001-evidence-v1'||content.generator!==OTV_VERSION||content.benchmark!=='OTV-001')
    throw new Error('Unsupported fixture or generator version');
  if(!content.scope?.synthetic||content.scope?.spaceflight_validated!==false||content.scope?.native_ecai_retrieval!==false||content.scope?.damagebdd_execution!==false)
    throw new Error('Invalid verification scope');
  const replay=evaluateTransfer(simulateTransfer({scenario:content.scenario,seed:content.seed}));
  if(!isDeepStrictEqual(replay.trace,content.trace)||!isDeepStrictEqual(replay.initial,content.initial)||!isDeepStrictEqual(replay.result,content.result))
    throw new Error('Deterministic replay or invariant results do not match evidence');
  return {status:'PASS',scenario:content.scenario,seed:content.seed,sha256,findings:replay.result.failed_invariant_count};
}

if(process.argv[1]?.endsWith('verify_otv_evidence.mjs')){
  const file=process.argv[2];
  if(!file){console.error('Usage: node verify_otv_evidence.mjs EVIDENCE.json');process.exitCode=2;}
  else try{const doc=JSON.parse(await readFile(file,'utf8'));const result=verifyEvidence(doc);console.log(JSON.stringify(result,null,2));}
  catch(error){console.error(`INVALID: ${error.message}`);process.exitCode=1;}
}
