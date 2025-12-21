(() => {
  const root = document.getElementById('lightning-swap-demo');
  console.log('swap demo root:', root);
  if (!root) return;

  const steps = root.querySelectorAll('.swap-step');
  const indicators = root.querySelectorAll('.swap-steps .step');

  let current = 'select';

  function show(step) {
    if (step !== 'select') {
      toggleDetails()
    }
    current = step;
    steps.forEach(el => el.classList.toggle('hidden', el.dataset.step !== step));
    indicators.forEach(el =>
      el.classList.toggle('active', el.textContent.trim().toLowerCase() === step)
    );

    // when leaving select, ensure details panel is not mid-animation
    if (step !== 'select') {
      resetDetailsUI();
    }
  }

  // ---------------- Details toggle (Select step only) ----------------
  let detailsOpen = false; // set false if you want collapsed by default

  function getDetailsEls() {
    const selectStep = root.querySelector('.swap-step[data-step="select"]');
    if (!selectStep) return {};
    const btn = selectStep.querySelector('.details');
    const icon = selectStep.querySelector('.details-icon');
    const panel = selectStep.querySelector('.select-grid');
    return { btn, icon, panel };
  }

  function setIcon(open) {
    const { icon } = getDetailsEls();
    if (!icon) return;

    // right chevron when closed, down chevron when open
    icon.classList.toggle('fa-chevron-right', !open);
    icon.classList.toggle('fa-chevron-down', open);
  }

  function openDetails(animate = true) {
    const { panel } = getDetailsEls();
    if (!panel) return;

    detailsOpen = true;
    setIcon(true);

    if (!window.gsap || !animate) {
      panel.style.display = '';
      panel.style.height = '';
      panel.style.opacity = '';
      panel.style.marginTop = '';
      return;
    }

    // ensure measurable height
    panel.style.display = 'grid';

    window.gsap.killTweensOf(panel);
    window.gsap.fromTo(
      panel,
      { height: 0, opacity: 0, marginTop: 0 },
      {
        height: panel.scrollHeight,
        opacity: 1,
        marginTop: 8,
        duration: 0.25,
        ease: 'power2.out',
        onComplete: () => {
          panel.style.height = ''; // let it be auto after animation
        },
      }
    );
  }

  function closeDetails(animate = true) {
    const { panel } = getDetailsEls();
    if (!panel) return;

    detailsOpen = false;
    setIcon(false);

    if (!window.gsap || !animate) {
      panel.style.display = 'none';
      return;
    }

    window.gsap.killTweensOf(panel);
    // lock current height so we can animate to 0
    panel.style.height = `${panel.scrollHeight}px`;

    window.gsap.to(panel, {
      height: 0,
      opacity: 0,
      marginTop: 0,
      duration: 0.2,
      ease: 'power2.inOut',
      onComplete: () => {
        panel.style.display = 'none';
        panel.style.height = '';
      },
    });
  }

  function toggleDetails() {
    if (detailsOpen) closeDetails(true);
    else openDetails(true);
  }

  function resetDetailsUI() {
    // optional: force open state whenever you return to select
    // comment out if you want to persist state across steps
    detailsOpen = true;
    const { panel } = getDetailsEls();
    if (panel) {
      panel.style.display = 'grid';
      panel.style.height = '';
      panel.style.opacity = '';
      panel.style.marginTop = '';
    }
    setIcon(true);
  }

  // ---------------- Main click delegation ----------------
  root.addEventListener('click', (e) => {
    const primary = e.target.closest('.primary-btn');
    const secondary = e.target.closest('.secondary-btn');
    const detailsBtn = e.target.closest('.details');

    // stop page scroll / submit weirdness
    if (primary || secondary || detailsBtn) {
      e.preventDefault();
      e.stopPropagation();
    }

    if (detailsBtn && current === 'select') {
      toggleDetails();
      return;
    }

    if (primary) {
      if (current === 'select') {
        show('confirm')
        toggleDetails()
      }
      else if (current === 'confirm') {
        show('status');
      }
      return;
    }

    if (secondary) {
      show('select');
      return;
    }
  });

  // Init
  show('select');

  // Set initial details state
  // If you want collapsed by default: set detailsOpen=false above, then call closeDetails(false)
  if (detailsOpen) openDetails(false);
  else closeDetails(false);
})();
