// @ts-check

/**
 * Reference or define the Bugzilla app namespace.
 * @namespace
 */
var Bugzilla = Bugzilla || {}; // eslint-disable-line no-var

/**
 * A simple data table implementation.
 */
Bugzilla.DataTable = class DataTable {
  /** @type {HTMLTableCaptionElement} */
  #$caption;
  /** @type {HTMLTableElement} */
  #$table;
  /** @type {HTMLTableRowElement} */
  #$theadRow;
  /** @type {HTMLTableSectionElement} */
  #$tbody;
  /** @type {HTMLElement} */
  #$message;

  #defaultStrings = {
    LOADING: 'Loading...',
    EMPTY: 'No results found.',
    ERROR: 'There was an error while loading the data.',
  };

  /**
   * Initialize a `DataTable` instance.
   * @param {{
   *   container: string,
   *   columns: {
   *     key: string,
   *     label: string,
   *     sortable?: boolean,
   *     formatter?: Function | string,
   *     allowHTML?: boolean,
   *     className?: string,
   *     sortOptions?: {
   *       defaultDir?: 'ascending' | 'descending',
   *       sortFunction?: Function,
   *     },
   *   }[],
   *   data?: { [key: string]: any }[],
   *   strings?: { [key: string]: string },
   *   options?: {
   *     formatRow?: Function,
   *     expandRow?: Function,
   *   },
   * }} args Arguments.
   */
  constructor({ container, columns, data = [], strings = {}, options = {} }) {
    /** @type {HTMLElement} */
    this.$container = document.querySelector(container);
    this.columns = columns;
    this.strings = strings;
    this.options = options;
    this.data = data;
    /** @type {{ [key: string]: 'ascending' | 'descending' }} */
    this.sortState = {};
    this.lastSortKey = '';

    columns.forEach(({ key, sortable, sortOptions: { defaultDir } = {} }) => {
      if (sortable && defaultDir) {
        this.sortState[key] = defaultDir;
      }
    });

    this.$container.innerHTML = `
      <div class="data-table-container" aria-label="${this.strings.TITLE || ''}">
        <table class="data-table responsive">
          <caption hidden></caption>
          <thead>
            <tr></tr>
          </thead>
          <tbody>
          </tbody>
        </table>
        <div class="message" hidden></div>
      </div>
    `;

    this.#$caption = this.$container.querySelector('caption');
    this.#$table = this.$container.querySelector('table');
    this.#$theadRow = this.$container.querySelector('thead tr');
    this.#$tbody = this.$container.querySelector('tbody');
    this.#$message = this.$container.querySelector('.message');

    this.setCaption(this.strings.CAPTION);
    this.#renderHead();

    if (data.length) {
      this.render(data);
    }
  }

  /**
   * Render the `<thead>` content.
   */
  #renderHead() {
    const $theadFragment = document.createDocumentFragment();

    this.columns.forEach(({ key, label, sortable = true, className }) => {
      const $column = $theadFragment.appendChild(document.createElement('th'));

      $column.innerHTML = `
        <span class="label">${label}</span>
        <span class="icon" aria-hidden="true"></span>
      `;

      if (sortable) {
        const _sort = () => {
          const order = this.sortState[key] === 'ascending' ? 'descending' : 'ascending';

          this.sort(key, order);
          $column.setAttribute('aria-sort', order);
        };

        $column.tabIndex = 0;
        $column.setAttribute('aria-sort', this.sortState[key] || 'none');
        $column.addEventListener('click', () => {
          _sort();
        });
        $column.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            _sort();
          }
        });
      }

      $column.dataset.key = key;

      if (className) {
        $column.classList.add(className);
      }
    });

    this.#$theadRow.innerHTML = '';
    this.#$theadRow.appendChild($theadFragment);
  }

  /**
   * Render the `<tbody>` content.
   */
  #renderBody() {
    const $tbodyFragment = document.createDocumentFragment();

    this.data.forEach((row) => {
      const { data } = row;
      const $row = $tbodyFragment.appendChild(document.createElement('tr'));

      const uuid =
        typeof window.crypto.randomUUID === 'function'
          ? window.crypto.randomUUID() // Not available on insecure test environment
          : URL.createObjectURL(new Blob([])).split('/').pop();

      $row.id = `row-${uuid.split('-').pop()}`;

      // Add DOM reference
      row.$row = $row;

      this.columns.forEach(({ key, label, formatter, allowHTML = false, className }) => {
        const $column = $row.appendChild(document.createElement('td'));

        $column.dataset.key = key;
        $column.dataset.columnLabel = label || key;

        if (className) {
          $column.classList.add(className);
        }

        if (key === '_expander') {
          if (typeof this.options.expandRow === 'function') {
            $column.innerHTML = `
              <button type="button" class="expander" aria-label="Expand" aria-expanded="false">
                <span class="icon" aria-hidden="true"></span>
              </button>
            `;
            row.$expander = $column.querySelector('button');
            row.$expander.addEventListener('click', () => {
              this.#toggleExtra(row);
            });
          }

          return;
        }

        const value = data[key];
        const content =
          typeof formatter === 'function'
            ? formatter({ $column, value, data })
            : typeof formatter === 'string'
            ? formatter.replaceAll('{value}', value)
            : value;

        if (content === undefined) {
          return;
        }

        if (allowHTML) {
          if (typeof content === 'string') {
            $column.innerHTML = content;
          } else {
            $column.appendChild(content);
          }
        } else {
          $column.textContent = content;
        }
      });

      if (typeof this.options.formatRow === 'function') {
        this.options.formatRow({ $row, data });
      }
    });

    this.#$tbody.innerHTML = '';
    this.#$tbody.appendChild($tbodyFragment);
  }

  /**
   * Expand or collapse a row’s extra data.
   * @param {{ [key: string]: any }} row Row data.
   */
  #toggleExtra(row) {
    const { $row, $expander, $extraRow } = row;
    const isExpanded = $expander.matches('[aria-expanded="true"]');

    $expander.setAttribute('aria-expanded', isExpanded ? 'false' : 'true');
    $expander.setAttribute('aria-label', isExpanded ? 'Expand' : 'Collapse');

    if (isExpanded) {
      $extraRow.hidden = true;
    } else if ($extraRow) {
      $extraRow.hidden = false;
    } else {
      $row.insertAdjacentHTML(
        'afterend',
        `
        <tr id="${$row.id}-extra"><td></td><td colspan="6"></td></tr>
      `,
      );
      row.$extraRow = $row.nextElementSibling;
      row.$extraContent = row.$extraRow.querySelector('[colspan]');
      $expander.setAttribute('aria-controls', `${$row.id}-extra`);
      this.options.expandRow(row);
    }
  }

  /**
   * Render the table using the given data.
   * @param {{ [key: string]: any }[]} data Table data.
   */
  render(data) {
    this.data = data.map((rowData) => ({ data: rowData }));

    this.setMessage(this.data.length ? '' : 'EMPTY');
    this.#sortData();
    this.#renderBody();
  }

  /**
   * Update the table with the given data or error.
   * @param {object} args Arguments.
   */
  update({ results }) {
    if (results) {
      this.render(results);
    } else {
      this.render([]);
      this.setMessage('ERROR');
    }
  }

  /**
   * Sort the data.
   */
  #sortData() {
    const key = this.lastSortKey;

    if (!key) {
      return;
    }

    const desc = this.sortState[key] === 'descending';
    const { sortFunction } = this.columns.find((c) => c.key === key).sortOptions ?? {};

    this.data.sort(({ data: a }, { data: b }) => {
      if (typeof sortFunction === 'function') {
        return sortFunction({ a, b, desc, key });
      }

      if (desc) {
        [a, b] = [b, a];
      }

      if (typeof a[key] === 'number') {
        return a[key] - b[key];
      }

      return String(a[key]).localeCompare(String(b[key]));
    });
  }

  /**
   * Sort the data and rerender the table.
   * @param {string} key Sort key.
   * @param {'ascending' | 'descending'} order Sort order.
   */
  sort(key, order) {
    this.lastSortKey = key;
    this.sortState[key] = order;
    this.#sortData();

    // Detach from DOM
    this.#$tbody.remove();

    this.data.forEach(({ $row, $extraRow }) => {
      this.#$tbody.appendChild($row);

      if ($extraRow) {
        this.#$tbody.appendChild($extraRow);
      }
    });

    // Add it back to DOM
    this.#$table.appendChild(this.#$tbody);
  }

  /**
   * Show or hide a message.
   * @param {string} message Message text.
   */
  setMessage(message) {
    this.#$table.hidden = Object.keys(this.#defaultStrings).includes(message);
    this.#$message.innerHTML =
      this.strings[message] || this.#defaultStrings[message] || message || '';
    this.#$message.hidden = !message;
  }

  /**
   * Show or hide the caption.
   * @param {string} caption Caption text.
   */
  setCaption(caption) {
    this.#$caption.innerHTML = caption || '';
    this.#$caption.hidden = !caption;
  }
};
