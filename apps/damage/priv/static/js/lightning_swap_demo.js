(() => {
  const root = document.getElementById("lightning-swap-demo");
  console.log("swap demo root:", root);
  if (!root) return;

  const steps = root.querySelectorAll(".swap-step");
  const indicators = root.querySelectorAll(".swap-steps .step");

  let current = "select";

  function animateValueTextIn(container, opts = {}) {
    if (!window.gsap || !container) return;

    const texts = Array.from(container.querySelectorAll(".value .value-text"));
    if (!texts.length) return;

    window.gsap.killTweensOf(texts);

    // reset so it can replay cleanly
    window.gsap.set(texts, { opacity: 0, x: -50 });

    window.gsap.to(texts, {
      opacity: 1,
      x: 0,
      duration: 1,
      ease: "bounce",
      stagger: 0.8,
      delay: opts.delay ?? 0,
      clearProps: "transform",
    });
  }

  function boltVerticalPullAnim(tl, at = 0) {
    const title = root.querySelector(".swap-title");
    if (!title) return;

    // wrap ⚡ once
    if (!title.querySelector(".bolt")) {
      title.innerHTML = title.innerHTML.replace(
        "⚡",
        '<span class="bolt">⚡</span>',
      );
    }

    const bolt = title.querySelector(".bolt");
    if (!bolt) return;

    tl.fromTo(
      bolt,
      { scaleY: 1, scaleX: 1, x: 0 },
      {
        scaleY: 2, // vertical pull
        scaleX: 0.82, // horizontal squash
        duration: 0.14,
        x: -5,
        ease: "power2.out",
      },
      at,
    )
      // slight extra tension
      .to(
        bolt,
        {
          scaleY: 1.7,
          scaleX: 0.78,
          duration: 0.06,
          ease: "power1.inOut",
        },
        ">",
      )
      // snap back with bounce
      .to(
        bolt,
        {
          scaleY: 1,
          scaleX: 1,
          duration: 0.55,
          x: 0,
          ease: "elastic.out(1, 0.45)",
        },
        ">",
      );
  }

  function titleIntroAnim() {
    if (!window.gsap) return;

    const title = root.querySelector(".swap-title");
    if (!title) return;

    const tl = gsap.timeline();

    // Title scales up then settles
    tl.fromTo(
      title,
      { scale: 1 },
      { scale: 1.1, duration: 0.18, ease: "power2.out" },
    ).to(title, {
      scale: 1,
      duration: 1,

      ease: "bounce.out", // or elastic.out for smoother
    });

    // Bolt stretch starts DURING the scale-up
    boltVerticalPullAnim(tl, 1);
  }

  // ---------------- Details toggle (Select step only) ----------------

  function show(step) {
    if (step !== "select") {
      toggleDetails();
    }

    current = step;

    steps.forEach((el) =>
      el.classList.toggle("hidden", el.dataset.step !== step),
    );
    indicators.forEach((el) =>
      el.classList.toggle(
        "active",
        el.textContent.trim().toLowerCase() === step,
      ),
    );

    // when leaving select, ensure details panel is not mid-animation
    if (step !== "select") {
      resetDetailsUI();
    }

    // ✅ Animate the value *text* inside the visible step (confirm-grid, select-grid, etc.)
    const visibleStep = root.querySelector(`.swap-step[data-step="${step}"]`);
    if (visibleStep) {
      animateValueTextIn(visibleStep, { delay: 0.05 });
    }
  }

  let detailsOpen = false; // set false if you want collapsed by default

  function getDetailsEls() {
    const selectStep = root.querySelector('.swap-step[data-step="select"]');
    if (!selectStep) return {};
    const btn = selectStep.querySelector(".details");
    const icon = selectStep.querySelector(".details-icon");
    const panel = selectStep.querySelector(".select-grid");
    return { btn, icon, panel };
  }

  function setIcon(open) {
    const { icon } = getDetailsEls();
    if (!icon) return;

    // right chevron when closed, down chevron when open
    icon.classList.toggle("fa-chevron-right", !open);
    icon.classList.toggle("fa-chevron-down", open);
  }

  // function openDetails(animate = true) {
  //   const { panel } = getDetailsEls();
  //   if (!panel) return;

  //   detailsOpen = true;
  //   setIcon(true);

  //   if (!window.gsap || !animate) {
  //     panel.style.display = "";
  //     panel.style.height = "";
  //     panel.style.opacity = "";
  //     panel.style.marginTop = "";
  //     return;
  //   }

  //   // ensure measurable height
  //   panel.style.display = "grid";

  //   window.gsap.killTweensOf(panel);
  //   window.gsap.fromTo(
  //     panel,
  //     { height: 0, opacity: 0, marginTop: 0 },
  //     {
  //       height: panel.scrollHeight,
  //       opacity: 1,
  //       marginTop: 8,
  //       duration: 0.25,
  //       ease: "power2.out",
  //       onComplete: () => {
  //         panel.style.height = ""; // let it be auto after animation
  //       },
  //     },
  //   );
  // }

  function openDetails(animate = true) {
    const { panel } = getDetailsEls();
    if (!panel) return;

    detailsOpen = true;
    setIcon(true);

    // ensure measurable height
    panel.style.display = "grid";

    // ✅ Animate the value *text* inside the details panel
    animateValueTextIn(panel, { delay: animate ? 0.08 : 0 });

    if (!window.gsap || !animate) {
      panel.style.height = "";
      panel.style.opacity = "";
      panel.style.marginTop = "";
      return;
    }

    window.gsap.killTweensOf(panel);
    window.gsap.fromTo(
      panel,
      { height: 0, opacity: 0, marginTop: 0 },
      {
        height: panel.scrollHeight,
        opacity: 1,
        marginTop: 8,
        duration: 0.25,
        ease: "power2.out",
        onComplete: () => {
          panel.style.height = ""; // let it be auto after animation
        },
      },
    );
  }

  function closeDetails(animate = true) {
    const { panel } = getDetailsEls();
    if (!panel) return;

    detailsOpen = false;
    setIcon(false);

    if (!window.gsap || !animate) {
      panel.style.display = "none";
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
      ease: "power2.inOut",
      onComplete: () => {
        panel.style.display = "none";
        panel.style.height = "";
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
      panel.style.display = "grid";
      panel.style.height = "";
      panel.style.opacity = "";
      panel.style.marginTop = "";
    }
    setIcon(true);
  }

  // ---------------- Main click delegation ----------------
  root.addEventListener("click", (e) => {
    const primary = e.target.closest(".primary-btn");
    const secondary = e.target.closest(".secondary-btn");
    const detailsBtn = e.target.closest(".details");

    // stop page scroll / submit weirdness
    if (primary || secondary || detailsBtn) {
      e.preventDefault();
      e.stopPropagation();
    }

    if (detailsBtn && current === "select") {
      toggleDetails();
      return;
    }

    if (primary) {
      if (current === "select") {
        show("confirm");
        toggleDetails();
      } else if (current === "confirm") {
        show("status");
      }
      return;
    }

    if (secondary) {
      show("select");
      return;
    }
  });

  // Init
  show("select");
  titleIntroAnim();

  // Set initial details state
  // If you want collapsed by default: set detailsOpen=false above, then call closeDetails(false)
  if (detailsOpen) openDetails(false);
  else closeDetails(false);
})();
