const loadData = async () => {
    try {
        const response = await fetch('/steps.json');
        const data = await response.json();
        console.log(data);
		return data;
        // process the data here
    } catch (error) {
        console.error('Error loading data:', error);
    }
};


const suggestions = loadData();

document.addEventListener('DOMContentLoaded', () => {
    const containerEle = document.getElementById('container');
    const textarea = document.getElementById('textarea');

    const mirroredEle = document.createElement('div');
    mirroredEle.textContent = textarea.value;
    mirroredEle.classList.add('container__mirror');
    containerEle.prepend(mirroredEle);

    const suggestionsEle = document.createElement('div');
    suggestionsEle.classList.add('container__suggestions');
    containerEle.appendChild(suggestionsEle);

    const textareaStyles = window.getComputedStyle(textarea);
    [
        'border',
        'boxSizing',
        'fontFamily',
        'fontSize',
        'fontWeight',
        'letterSpacing',
        'lineHeight',
        'padding',
        'textDecoration',
        'textIndent',
        'textTransform',
        'whiteSpace',
        'wordSpacing',
        'wordWrap',
    ].forEach((property) => {
        mirroredEle.style[property] = textareaStyles[property];
    });
    mirroredEle.style.borderColor = 'transparent';

    const parseValue = (v) => v.endsWith('px') ? parseInt(v.slice(0, -2), 10) : 0;
    const borderWidth = parseValue(textareaStyles.borderWidth);

    const ro = new ResizeObserver(() => {
        mirroredEle.style.width = `${textarea.clientWidth + 2 * borderWidth}px`;
        mirroredEle.style.height = `${textarea.clientHeight + 2 * borderWidth}px`;
    });
    ro.observe(textarea);

    textarea.addEventListener('scroll', () => {
        mirroredEle.scrollTop = textarea.scrollTop;
    });

    const findIndexOfCurrentWord = () => {
        // Get current value and cursor position
        const currentValue = textarea.value;
        const cursorPos = textarea.selectionStart;

        // Iterate backwards through characters until we find a space or newline character
        let startIndex = cursorPos - 1;
        while (startIndex >= 0 && !/\s/.test(currentValue[startIndex])) {
            startIndex--;
        }
        return startIndex;
    };

    // Replace current word with selected suggestion
    const replaceCurrentWord = (newWord) => {
        const currentValue = textarea.value;
        const cursorPos = textarea.selectionStart;
        const startIndex = findIndexOfCurrentWord();

        const newValue = currentValue.substring(0, startIndex + 1) +
              newWord +
              currentValue.substring(cursorPos);
        textarea.value = newValue;
        textarea.focus();
        textarea.selectionStart = textarea.selectionEnd = startIndex + 1 + newWord.length;
    };

    textarea.addEventListener('input', () => {
        const currentValue = textarea.value;
        const cursorPos = textarea.selectionStart;
        const startIndex = findIndexOfCurrentWord();

        // Extract just the current word
        const currentWord = currentValue.substring(startIndex + 1, cursorPos);
        if (currentWord === '') {
            return;
        }

        const matches = suggestions.filter((suggestion) => suggestion.indexOf(currentWord) > -1);
        if (matches.length === 0) {
            suggestionsEle.style.display = 'none';
            return;
        }

        const textBeforeCursor = currentValue.substring(0, cursorPos);
        const textAfterCursor = currentValue.substring(cursorPos);

        const pre = document.createTextNode(textBeforeCursor);
        const post = document.createTextNode(textAfterCursor);
        const caretEle = document.createElement('span');
        caretEle.innerHTML = '&nbsp;';

        mirroredEle.innerHTML = '';
        mirroredEle.append(pre, caretEle, post);

        const rect = caretEle.getBoundingClientRect();
        suggestionsEle.style.top = `${rect.top + rect.height}px`;
        suggestionsEle.style.left = `${rect.left}px`;

        suggestionsEle.innerHTML = '';
        matches.forEach((match) => {
            const option = document.createElement('div');
            option.innerText = match;
            option.classList.add('container__suggestion');
            option.addEventListener('click', function() {
                replaceCurrentWord(this.innerText);
                suggestionsEle.style.display = 'none';
            });
            suggestionsEle.appendChild(option);
        });
        suggestionsEle.style.display = 'block';
    });
});
