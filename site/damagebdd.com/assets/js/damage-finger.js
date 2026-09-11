document.addEventListener("DOMContentLoaded", () => {
  const editor = document.getElementById("editor");
  const completer = document.getElementById("completer");
  const micInput = document.getElementById("mic-input");
  const featureName = document.getElementById("feature-name");
  const micButton = document.getElementById("mic-record");

  const stepOptions = {
    start: ["Feature"],
    step: ["Background", "Given", "When", "Then"],
    background: ["Given", "When", "Then"]
  };

  editor.addEventListener("focus", () => showCompleter("start"));

  editor.addEventListener("click", () => {
    const cursorLine = getCurrentLine();
    if (/^Feature/.test(cursorLine)) {
      showCompleter("step");
    } else if (cursorLine.trim() === "") {
      showCompleter("start");
    }
  });

  function getCurrentLine() {
    const pos = editor.selectionStart;
    const textUptoCursor = editor.value.substring(0, pos);
    const lines = textUptoCursor.split("\n");
    return lines[lines.length - 1];
  }

  function showCompleter(type) {
    completer.innerHTML = "";
    completer.classList.remove("hidden");
    (stepOptions[type] || []).forEach(opt => {
      const btn = document.createElement("button");
      btn.textContent = opt;
      btn.onclick = () => handleCompletion(opt);
      completer.appendChild(btn);
    });
  }

  function showFeatureNameEditor() {
    micInput.classList.remove("hidden");
    featureName.focus();
  }

  featureName.addEventListener("change", () => {
    insertLine(`Feature: ${featureName.value}`);
    micInput.classList.add("hidden");
  });

  micButton.addEventListener("click", () => {
    alert("🎤 Microphone feature placeholder. Use Web Speech API to enable.");
  });

  function handleCompletion(step) {
    if (step === "Feature") {
      showFeatureNameEditor();
    } else if (step === "Background") {
      insertLine("Background:");
      showCompleter("background");
    } else {
      insertLine(`${step} `);
      completer.classList.add("hidden");
    }
  }

  function insertLine(text) {
    const pos = editor.selectionStart;
    const before = editor.value.substring(0, pos);
    const after = editor.value.substring(pos);
    editor.value = before + (before.endsWith("\n") ? "" : "\n") + text + "\n" + after;
    editor.focus();
  }
    const moveLine = (dir) => {
      const editor = document.getElementById("editor");
      const pos = editor.selectionStart;
      const lines = editor.value.split("\n");
      let start = 0;

      for (let i = 0; i < lines.length; i++) {
        if (pos <= start + lines[i].length) {
          if ((dir === "up" && i === 0) || (dir === "down" && i === lines.length - 1)) return;
          const j = dir === "up" ? i - 1 : i + 1;
          [lines[i], lines[j]] = [lines[j], lines[i]];
          editor.value = lines.join("\n");
          editor.setSelectionRange(start, start);
          editor.focus();
          break;
        }
        start += lines[i].length + 1;
      }
    };

    document.getElementById("move-up").onclick = () => moveLine("up");
    document.getElementById("move-down").onclick = () => moveLine("down");
});
