// thumb-bdd-picker.js
// Thumb-optimized BDD Step Picker Widget for DamageBDD

export function initStepPicker({ containerId, featureContainerId, stepsDefinition }) {
  const container = document.getElementById(containerId);
  const featureContainer = document.getElementById(featureContainerId);

  if (!container || !featureContainer) {
    console.error("Missing container elements for Step Picker.");
    return;
  }

  // Build UI: a button for each step type
  Object.keys(stepsDefinition).forEach(stepName => {
    const stepButton = document.createElement("button");
    stepButton.textContent = stepName;
    stepButton.className = "step-picker-button";
    stepButton.onclick = () => openStepInput(stepName, stepsDefinition[stepName], featureContainer);
    container.appendChild(stepButton);
  });
}

function openStepInput(stepName, stepTemplate, featureContainer) {
  const paramMatches = stepTemplate.match(/\{\{(.*?)\}\}/g) || [];
  const paramNames = paramMatches.map(m => m.replace(/\{\{|\}\}/g, ""));

  const inputDiv = document.createElement("div");
  inputDiv.className = "step-input-form";

  const title = document.createElement("h3");
  title.textContent = `Fill parameters for: ${stepName}`;
  inputDiv.appendChild(title);

  const inputs = {};

  paramNames.forEach(param => {
    const label = document.createElement("label");
    label.textContent = param;
    inputDiv.appendChild(label);

    const input = document.createElement("input");
    input.type = "text";
    inputDiv.appendChild(input);

    inputs[param] = input;
  });

  const addButton = document.createElement("button");
  addButton.textContent = "➕ Add Step";
  addButton.className = "add-step";
  addButton.onclick = () => {
    let filledStep = stepTemplate;
    paramNames.forEach(param => {
      filledStep = filledStep.replace(`{{${param}}}`, inputs[param].value);
    });
    addStepToFeature(featureContainer, filledStep);
    inputDiv.remove();
  };
  inputDiv.appendChild(addButton);

  featureContainer.parentNode.insertBefore(inputDiv, featureContainer.nextSibling);
}

function addStepToFeature(featureContainer, filledStep) {
  const stepLine = document.createElement("div");
  stepLine.textContent = filledStep;
  stepLine.className = "feature-step-line";
  featureContainer.appendChild(stepLine);
}

/*
Usage Example:

import { initStepPicker } from './thumb-bdd-picker.js';

initStepPicker({
  containerId: 'step-picker',
  featureContainerId: 'feature-steps',
  stepsDefinition: {
    'Given I am using server "{{Server}}"': 'Given I am using server "{{Server}}"',
    'When I make a GET request to "{{Path}}"': 'When I make a GET request to "{{Path}}"',
    'Then the response must contain text "{{Text}}"': 'Then the response must contain text "{{Text}}"'
  }
});
*/
