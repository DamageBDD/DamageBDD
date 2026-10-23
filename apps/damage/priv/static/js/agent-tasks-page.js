import {mountAgentTasks} from './agent-tasks.js';
const root = document.getElementById('agent-tasks');
if (root) {
  const dispose = mountAgentTasks(root);
  window.addEventListener('pagehide',dispose,{once:true});
}
