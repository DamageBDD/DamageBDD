document.addEventListener('DOMContentLoaded', () => {
  const textarea = document.getElementById('damageTextArea');
  const gutter = document.getElementById('damageLineNumbers');

  if (!textarea || !gutter) {
    return;
  }

  let activeEditor = null;
  let measurementNeedsSync = true;

  const measurementDiv = document.createElement('div');
  Object.assign(measurementDiv.style, {
    position: 'absolute',
    visibility: 'hidden',
    whiteSpace: 'pre-wrap',
    wordWrap: 'break-word',
    overflowWrap: 'break-word',
    top: '0',
    left: '-9999px',
    pointerEvents: 'none',
    zIndex: -1,
  });
  document.body.appendChild(measurementDiv);

  const parsePx = (value) => (typeof value === 'string' ? parseFloat(value) : Number(value)) || 0;

  const copyMeasurementStyles = () => {
    const computed = window.getComputedStyle(textarea);
    const propertiesToCopy = [
      'fontFamily',
      'fontSize',
      'fontWeight',
      'fontStyle',
      'lineHeight',
      'letterSpacing',
      'textTransform',
      'textIndent',
      'textDecoration',
    ];
    propertiesToCopy.forEach((prop) => {
      measurementDiv.style[prop] = computed[prop];
    });
    const paddingLeft = parsePx(computed.paddingLeft);
    const paddingRight = parsePx(computed.paddingRight);
    const contentWidth = Math.max(
      0,
      textarea.clientWidth - paddingLeft - paddingRight,
    );
    measurementDiv.style.width = `${contentWidth || textarea.clientWidth}px`;
    measurementDiv.style.boxSizing = 'content-box';
    measurementNeedsSync = false;
  };

  const ensureMeasurementSync = () => {
    if (measurementNeedsSync) {
      copyMeasurementStyles();
    }
  };

  const getTextareaMeasurementHeight = () => {
    ensureMeasurementSync();
    const value = textarea.value;
    measurementDiv.textContent = value ? `${value}\n` : '\u200b';
    return measurementDiv.scrollHeight;
  };

  const getLineHeight = (element, fallback = 18) => {
    if (!element) {
      return fallback;
    }
    const computed = window.getComputedStyle(element);
    const lineHeight = parseFloat(computed.lineHeight);
    if (Number.isFinite(lineHeight)) {
      return lineHeight;
    }
    const fontSize = parseFloat(computed.fontSize);
    if (Number.isFinite(fontSize)) {
      return fontSize * 1.2;
    }
    return fallback;
  };

  const getLogicalLineCount = () => Math.max(
    1,
    getCurrentValue().split(/\r\n|\r|\n/).length,
  );

  const getTextareaVisualLineCount = () => {
    const lineHeight = getLineHeight(textarea);
    const measurementHeight = getTextareaMeasurementHeight();
    const visualLinesFromHeight = Math.round(measurementHeight / lineHeight);
    return Math.max(getLogicalLineCount(), visualLinesFromHeight);
  };

  const getEditorVisualLineCount = () => {
    if (!activeEditor || typeof activeEditor.getScrollerElement !== 'function') {
      return 1;
    }
    const scroller = activeEditor.getScrollerElement();
    if (!scroller) {
      return 1;
    }
    const lineHeight = typeof activeEditor.defaultTextHeight === 'function'
      ? activeEditor.defaultTextHeight()
      : getLineHeight(textarea);
    const approximateLines = Math.round(scroller.scrollHeight / lineHeight);
    return Math.max(1, approximateLines);
  };

  const getVisualLineCount = () => {
    if (activeEditor) {
      return getEditorVisualLineCount();
    }
    return getTextareaVisualLineCount();
  };

  const getCurrentValue = () => {
    if (activeEditor) {
      return activeEditor.getValue();
    }
    return textarea.value;
  };

  const syncScroll = () => {
    if (activeEditor) {
      const scroller = activeEditor.getScrollerElement();
      gutter.scrollTop = scroller.scrollTop;
    } else {
      gutter.scrollTop = textarea.scrollTop;
    }
  };

  const renderLineNumbers = () => {
    const totalLines = getVisualLineCount();
    const lines = [];
    for (let i = 1; i <= totalLines; i += 1) {
      lines.push(`<span>${i}</span>`);
    }
    gutter.innerHTML = lines.join('');
    syncScroll();
  };

  const debouncedRender = () => {
    window.requestAnimationFrame(renderLineNumbers);
  };

  const wireUpTextarea = () => {
    textarea.addEventListener('input', debouncedRender);
    textarea.addEventListener('change', debouncedRender);
    textarea.addEventListener('scroll', syncScroll);
  };

  const wireUpEditor = (editor) => {
    activeEditor = editor;
    editor.on('change', debouncedRender);
    editor.on('scroll', syncScroll);
    debouncedRender();
  };

  const valueDescriptor = Object.getOwnPropertyDescriptor(
    Object.getPrototypeOf(textarea),
    'value',
  );

  if (valueDescriptor && valueDescriptor.configurable) {
    Object.defineProperty(textarea, 'value', {
      configurable: true,
      enumerable: valueDescriptor.enumerable,
      get() {
        return valueDescriptor.get.call(this);
      },
      set(val) {
        valueDescriptor.set.call(this, val);
        debouncedRender();
      },
    });
  }

  wireUpTextarea();
  debouncedRender();

  window.addEventListener('resize', () => {
    measurementNeedsSync = true;
    debouncedRender();
  });

  window.addEventListener('damage-editor-ready', (event) => {
    if (event.detail && event.detail.editor) {
      wireUpEditor(event.detail.editor);
    }
  }, { once: true });

  if (window.damageEditor) {
    wireUpEditor(window.damageEditor);
  }
});
