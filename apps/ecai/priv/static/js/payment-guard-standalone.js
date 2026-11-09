import {initPaymentGuard} from './ecai-payment-guard.js?v=payment-guard-v1';
const root=document.getElementById('paymentGuard');root.hidden=false;
const workspace=initPaymentGuard({visible:true});
window.addEventListener('beforeunload',()=>workspace.dispose(),{once:true});
