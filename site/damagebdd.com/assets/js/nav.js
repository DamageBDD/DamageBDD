document.querySelectorAll('.has-submenu > .submenu-trigger').forEach(trigger => {
  trigger.addEventListener('click', e => {
    e.preventDefault();
    const parent = trigger.closest('.has-submenu');
    parent.classList.toggle('open');
  });
});

// Close submenu if clicked outside
document.addEventListener('click', e => {
  document.querySelectorAll('.has-submenu.open').forEach(menu => {
    if (!menu.contains(e.target)) {
      menu.classList.remove('open');
    }
  });
});

