/*
 * Progressive Enhancement der Library-of-Things-Seite.
 *
 * Ohne dieses Skript funktioniert die Seite vollstaendig (alle Kacheln
 * sichtbar, Infobox per details/summary bedienbar). Das Skript ergaenzt:
 *  - Suche ueber die Kacheltitel
 *  - Filter-Buttons nach Kategorie (Sammlungscode)
 *  - die Keine-Treffer-Kachel
 *  - Ausblenden von Kacheln mit kaputtem Bild
 *
 * Suche und Filter sind im Template mit hidden markiert und werden hier
 * erst eingeblendet, damit Nutzer ohne JavaScript keine toten Bedien-
 * elemente sehen.
 */
(function () {
  'use strict';

  var root = document.getElementById('library-of-things');
  if (!root) {
    return;
  }

  var controls = root.querySelector('.lot-controls');
  var tiles = Array.prototype.slice.call(root.querySelectorAll('.lot-tile'));
  var noResults = root.querySelector('.lot-no-results');
  var searchInput = root.querySelector('#lot-search');
  var filterButtons = Array.prototype.slice.call(root.querySelectorAll('.lot-filter-btn'));

  var activeFilter = '';
  var query = '';

  function tileMatches(tile) {
    if (tile.dataset.lotBroken === '1') {
      return false;
    }
    if (activeFilter) {
      var categories = (tile.getAttribute('data-category') || '').split(' ');
      if (categories.indexOf(activeFilter) === -1) {
        return false;
      }
    }
    if (query) {
      var label = tile.querySelector('.lot-label');
      var text = (label ? label.textContent : '').toLowerCase();
      if (text.indexOf(query) === -1) {
        return false;
      }
    }
    return true;
  }

  function applyFilters() {
    var visible = 0;
    tiles.forEach(function (tile) {
      var show = tileMatches(tile);
      tile.hidden = !show;
      if (show) {
        visible += 1;
      }
    });
    if (noResults) {
      noResults.hidden = visible !== 0;
    }
  }

  if (controls) {
    controls.hidden = false;
  }

  if (searchInput) {
    searchInput.addEventListener('input', function () {
      query = this.value.trim().toLowerCase();
      applyFilters();
    });
  }

  filterButtons.forEach(function (button) {
    button.addEventListener('click', function () {
      filterButtons.forEach(function (other) {
        other.classList.remove('lot-filter-active');
      });
      this.classList.add('lot-filter-active');
      activeFilter = this.getAttribute('data-filter') || '';
      applyFilters();
    });
  });

  // Kacheln ausblenden, deren Bild nicht geladen werden kann
  tiles.forEach(function (tile) {
    var image = tile.querySelector('img');
    if (!image) {
      return;
    }
    image.addEventListener('error', function () {
      tile.dataset.lotBroken = '1';
      applyFilters();
    });
  });
})();
