		var tags = [
			"feature",
			"scenario",
			"When",
			"Then",
			"Given"
				
		];
(function(window, document, undefined) {


	document.addEventListener("DOMContentLoaded", function() {
		function updatePopup(popupElem, textarea, caretPos) {
			let list_ends_on_start_tag = textarea.value.substring(0, caretPos).split("<");
			let start_tag = list_ends_on_start_tag[list_ends_on_start_tag.length-1];
			if(start_tag[0] == "/") start_tag = start_tag.substr(1);
			if(start_tag == "" || start_tag.includes(" ") || start_tag.includes(">")) {
				popupElem.innerHTML = "";
				return;
			}
			popupElem.innerText = "";
			tags.forEach((tag) => {
				if(tag.substring(0, start_tag.length) == start_tag) {
					console.log(tag, tag.substring(0, start_tag.length));
					let autocompleteButton = document.createElement("button");
					autocompleteButton.innerHTML = "<i>" + tag.substring(0, start_tag.length) + "</i>" + tag.substring(start_tag.length, tag.length);
					autocompleteButton.addEventListener("click", () => {
						textarea.parentElement.update(textarea.parentElement.value.substring(0, caretPos) + tag.substring(start_tag.length, tag.length) + textarea.parentElement.value.substr(caretPos)); // On code-input
						let newCaretPos = caretPos + tag.length - start_tag.length;
						textarea.focus();
						textarea.selectionStart = newCaretPos;
						textarea.selectionEnd = newCaretPos;
						popupElem.innerHTML = ""; // On popup
					});
					popupElem.appendChild(autocompleteButton);
				}
			});
			
			popupElem.firstElementChild.innerHTML += "[Tab]";
			textarea.addEventListener("keydown", (event) => {
				if(event.key == "Tab") {
					popupElem.firstElementChild.click();
					event.preventDefault();
				}
			});
		}
		codeInput.registerTemplate(
			"syntax-highlighted",
			codeInput.templates.hljs(
				hljs,
				[
					new codeInput.plugins.Autocomplete(updatePopup),
					new codeInput.plugins.Indent(true, 2) // 2 spaces indentation
				]
			)
		);
		hljs.highlightAll();

	});

})(window, document, undefined);
