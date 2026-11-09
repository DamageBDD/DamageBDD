import {initFoodRescue} from './ecai-food-rescue.js?v=food-rescue-v1';
const panel=document.getElementById('foodRescue');
if(panel){panel.hidden=false;const app=initFoodRescue({visible:true});window.addEventListener('beforeunload',()=>app.dispose(),{once:true});}
