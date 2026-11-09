import {initEnergyFlex} from './ecai-energyflex.js';
const root=document.getElementById('energyFlex');
root.hidden=false;
const demo=initEnergyFlex({root,visible:true});
window.addEventListener('beforeunload',()=>demo.dispose(),{once:true});
