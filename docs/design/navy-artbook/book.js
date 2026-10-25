const direction = document.querySelector('#direction');
const filter = document.querySelector('#screenfilter');
const surface = document.querySelector('#surface');
const modal = document.querySelector('#detail');
function updateView() {
  const web = surface.value === 'web';
  document.body.classList.toggle('compare-one', !web && filter.value !== 'all');
  document.body.classList.toggle('web-mode', web);
  filter.disabled = web;
  document.querySelectorAll('.webspread').forEach(el => el.hidden = !web);
  document.querySelectorAll('.mobilespread').forEach(el => el.hidden = web);
  document.querySelectorAll('.screenfigure').forEach(el => el.hidden = !web && filter.value !== 'all' && el.dataset.screen !== filter.value);
}
direction.addEventListener('change', () => {
  const el = document.getElementById(direction.value);
  if (el) { el.scrollIntoView({behavior:'instant'}); history.replaceState(null, '', '#'+direction.value); }
});
filter.addEventListener('change', updateView);
surface.addEventListener('change', updateView);
document.querySelector('#print').addEventListener('click', () => window.print());
document.querySelector('#close-dialog').addEventListener('click', () => modal.close());
document.addEventListener('click', event => {
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const title = button.dataset.action;
  const details = routeDetails[title];
  if (!details) return;
  const chapter = button.closest('.chapter');
  modal.style.cssText = chapter ? chapter.getAttribute('style') : '';
  document.querySelector('#dialogtitle').textContent = title;
  document.querySelector('#dialogbody').replaceChildren(...details.map(text => {
    const item = document.createElement('li'); item.textContent = text; return item;
  }));
  modal.showModal();
});
updateView();
