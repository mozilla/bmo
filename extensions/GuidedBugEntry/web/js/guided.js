/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

/**
 * Implement the guided bug entry wizard.
 */
class GuidedBugEntry {
  /**
   * Wizard steps.
   * @type {string[]}
   */
  static WIZARD_STEPS = ['product', 'dupes', 'form'];

  /**
   * Current step name.
   * @type {string}
   */
  static currentStep = '';

  /**
   * Default step name.
   * @type {string}
   */
  static defaultStep = 'product';

  /**
   * Whether to update the current step.
   * @type {boolean}
   */
  static updateStep = true;

  /**
   * Statuses considered "open" for following bugs.
   * @type {string[]}
   */
  static openStates = [];

  /**
   * Whether the web development entry flow is enabled.
   * @type {boolean}
   */
  static webdev = false;

  /**
   * Initiate a step change.
   * @param {string} newStep New step name.
   * @param {boolean} noSetHistory Whether to avoid updating history.
   */
  static setStep(newStep, noSetHistory) {
    this.updateStep = true;

    switch (newStep) {
      case 'webdev':
        GuidedBugEntryWebDevPage.onShow();
        break;
      case 'product':
        GuidedBugEntryProductPage.onShow();
        break;
      case 'other-products':
        GuidedBugEntryOtherProductsPage.onShow();
        break;
      case 'dupes':
        GuidedBugEntryOtherDupesPage.onShow();
        break;
      case 'bug-form':
        GuidedBugEntryFormPage.onShow();
        break;
      default:
        GuidedBugEntry.setStep(this.defaultStep, noSetHistory);
        return;
    }

    if (!this.updateStep) {
      return;
    }

    // change visibility of _step div
    if (this.currentStep) {
      document.querySelector(`#${this.currentStep}-step`).hidden = true;
    }

    this.currentStep = newStep;
    document.querySelector(`#${this.currentStep}-step`).hidden = false;

    // scroll to top of page to mimic real navigation
    scroll(0, 0);

    if (noSetHistory) {
      return;
    }

    const { search, pathname } = window.location;
    const params = new URLSearchParams(search);
    const isDefaultStep = newStep === this.defaultStep;
    const productName = isDefaultStep ? '' : GuidedBugEntryProductPage.productName;
    const componentName = isDefaultStep ? '' : GuidedBugEntryProductPage.preselectedComponent;

    if (productName) {
      params.set('product', productName);
    } else {
      params.delete('product');
    }

    if (componentName) {
      params.set('component', componentName);
    } else {
      params.delete('component');
    }

    window.history.pushState(
      {
        step: newStep,
        product: productName,
        component: componentName,
      },
      '',
      `${pathname}?${params.toString()}`,
    );
  }

  /**
   * Update the stepper indicators.
   * @param {'product' | 'dupes' | 'form'} page Page name.
   */
  static updateSteppers(page) {
    const wizardIndex = this.WIZARD_STEPS.indexOf(page);

    this.WIZARD_STEPS.forEach((step, index) => {
      const indicator = document.querySelector(`#stepper-${step}`);

      indicator.classList.toggle('done', index < wizardIndex);
      indicator.setAttribute('aria-current', index === wizardIndex ? 'step' : 'false');
    });
  }

  /**
   * Initialize the guided bug entry and history management.
   */
  static init() {
    const webdev = new URLSearchParams(location.search).get('webdev');

    if (webdev && webdev !== '0') {
      this.defaultStep = 'webdev';
      this.webdev = true;
    }

    document.querySelector('#steps').hidden = false;

    this.openStates = JSON.parse(document.querySelector('#guided').dataset.openStates);

    // init steps
    GuidedBugEntryProductPage.onInit();
    GuidedBugEntryOtherDupesPage.onInit();
    GuidedBugEntryFormPage.onInit();
    GuidedBugEntryFormPage.initHelp();

    const noSetHistory = !window.history.state;

    if (noSetHistory) {
      const { search, pathname } = window.location;
      const params = new URLSearchParams(search);
      const { product: productName, component: componentName } = Object.fromEntries(params);

      window.history.replaceState(
        {
          step: productName ? 'dupes' : this.defaultStep,
          product: productName ?? '',
          component: componentName ?? '',
        },
        '',
        `${pathname}?${params.toString()}`,
      );
    }

    this.onStateChange(noSetHistory);

    window.addEventListener('popstate', () => {
      this.onStateChange(true);
    });

    document.querySelectorAll('.product-link').forEach(($item) => {
      const handleEvent = (event) => {
        if (event.target.matches('p a')) {
          return;
        }

        event.preventDefault();

        const { link, product: productName, component: componentName } = $item.dataset;

        if (link) {
          if (!URL.canParse(link, location.href)) {
            return;
          }

          const { protocol, href } = new URL(link, location.href);

          // Only allow web links; never navigate to `javascript:` etc.
          if (!protocol.match(/^https?:$/)) {
            return;
          }

          if (event.metaKey || event.ctrlKey) {
            window.open(href, '_blank');
          } else {
            location.href = href;
          }
        } else if (productName === 'Other Products') {
          GuidedBugEntry.setStep('other-products');
        } else {
          GuidedBugEntryProductPage.select(productName, componentName);
        }
      };

      $item.addEventListener('click', (event) => {
        handleEvent(event);
      });

      $item.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          handleEvent(event);
        }
      });
    });

    document.querySelectorAll('[data-step]').forEach(($link) => {
      $link.addEventListener('click', (event) => {
        event.preventDefault();
        GuidedBugEntry.setStep($link.dataset.step);
      });
    });
  }

  /**
   * Callback for history state changes.
   * @param {boolean} noSetHistory Whether to avoid updating history.
   */
  static onStateChange(noSetHistory) {
    const { product, component, step } = window.history.state ?? {};

    GuidedBugEntryProductPage.preselectedComponent = component ?? '';
    GuidedBugEntryProductPage.setProduct(product ?? '');
    GuidedBugEntry.setStep(step, noSetHistory);
  }

  /**
   * Show or clear the inline error message for a field. The message element is keyed off the
   * field’s own ID, so repeated calls update it in place instead of stacking duplicates.
   * @param {HTMLElement} $field Field the message belongs to.
   * @param {string} [message] Message to show. Pass nothing to clear the error.
   */
  static setFieldError($field, message = '') {
    const id = `${$field.id}-error`;
    let $message = document.getElementById(id);

    if (!message) {
      $field.removeAttribute('aria-invalid');
      $field.removeAttribute('aria-errormessage');
      $message?.remove();

      return;
    }

    $field.setAttribute('aria-invalid', 'true');
    $field.setAttribute('aria-errormessage', id);

    if (!$message) {
      $message = document.createElement('div');
      $message.id = id;
      $message.className = 'error-message';
      $field.insertAdjacentElement('afterend', $message);
    }

    $message.textContent = message;
  }

  /**
   * Set the advanced bug entry link.
   */
  static setAdvancedLink() {
    const params = new URLSearchParams({ format: '__default__' });

    const { productName } = GuidedBugEntryProductPage;
    const { summary } = GuidedBugEntryOtherDupesPage;

    if (productName) {
      params.set('product', productName);
    }

    if (summary) {
      params.set('short_desc', summary);
    }

    const href = `${BUGZILLA.config.basepath}enter_bug.cgi?${params}`;

    document.querySelector('#advanced-link').href = href;
  }
}

/**
 * Web development product selection page.
 */
class GuidedBugEntryWebDevPage {
  /**
   * Show callback.
   */
  static onShow() {
    GuidedBugEntry.updateSteppers('product');
  }
}

/**
 * Product selection page.
 */
class GuidedBugEntryProductPage {
  /**
   * Loaded product details.
   * @type {{ components: { name: string, is_active: boolean }[], versions: { name: string,
   * is_active: boolean }[] } | null}
   */
  static details = null;

  /**
   * Preselected component name.
   * @type {string}
   */
  static preselectedComponent = '';

  /**
   * Currently loaded product name.
   * @type {string | null}
   */
  static loadedProductName = null;

  /**
   * Reference to the hidden product input element.
   * @type {HTMLInputElement}
   */
  static $product = null;

  /**
   * Reference to the product name label on the form page.
   * @type {HTMLElement}
   */
  static $productLabel = null;

  /**
   * Reference to the product name label on the duplicate search page.
   * @type {HTMLElement}
   */
  static $dupeProductName = null;

  /**
   * Reference to the “See All Components” link element.
   * @type {HTMLAnchorElement}
   */
  static $listComp = null;

  /**
   * Reference to the product support message container element.
   * @type {HTMLElement}
   */
  static $support = null;

  /**
   * Reference to the product support message element.
   * @type {HTMLElement}
   */
  static $supportMessage = null;

  /**
   * Reference to the component selection section element.
   * @type {HTMLElement}
   */
  static $componentSection = null;

  /**
   * Initialization callback.
   */
  static onInit() {
    this.$product = document.querySelector('#product');
    this.$productLabel = document.querySelector('#product-label');
    this.$dupeProductName = document.querySelector('#dupe-product-name');
    this.$listComp = document.querySelector('#list-comp');
    this.$support = document.querySelector('#product-support');
    this.$supportMessage = document.querySelector('#product-support-message');
    this.$componentSection = document.querySelector('#component-section');
  }

  /**
   * Show callback.
   */
  static onShow() {
    GuidedBugEntry.updateSteppers('product');
  }

  /**
   * Select a product and optional component.
   * @param {string} productName Product name.
   * @param {string} [componentName] Component name.
   */
  static select(productName, componentName) {
    const prod = products[productName];

    // called when a product is selected
    if (componentName) {
      if (prod?.defaultComponent) {
        prod.originalDefaultComponent = prod.originalDefaultComponent || prod.defaultComponent;
        prod.defaultComponent = componentName;
      }
    } else {
      if (prod?.defaultComponent && prod.originalDefaultComponent) {
        prod.defaultComponent = prod.originalDefaultComponent;
      }
    }

    this.preselectedComponent = prod?.defaultComponent || componentName || '';

    // This is a fresh choice by the user, so drop the component carried over from the previous
    // selection, then re-apply the preselection. `setProduct()` returns early when the product
    // itself hasn’t changed, so it can’t be relied on to do this.
    GuidedBugEntryFormPage.resetComponent();
    this.setProduct(productName);
    GuidedBugEntryFormPage.onProductUpdated();

    GuidedBugEntryOtherDupesPage.reset();
    GuidedBugEntry.setStep('dupes');
  }

  /**
   * Get the currently selected product name.
   */
  static get productName() {
    return this.$product.value;
  }

  /**
   * Get the currently selected product name and related products.
   */
  static get productNameAndRelated() {
    const { productName } = this;

    return [productName, ...(products[productName]?.related ?? [])];
  }

  /**
   * Get the component to be used as-is for the given product, without asking the user. This is
   * empty unless the product’s component selection is suppressed *and* a component is actually
   * known; otherwise the component selector has to be shown, because submitting the form without a
   * component always fails.
   * @param {string} [productName] Product name. Defaults to the selected product.
   * @returns {string} Component name, or an empty string if the user has to pick one.
   */
  static fixedComponent(productName = this.productName) {
    const { noComponentSelection, defaultComponent } = products[productName] ?? {};

    if (!noComponentSelection && !GuidedBugEntry.webdev) {
      return '';
    }

    return defaultComponent || this.preselectedComponent || '';
  }

  /**
   * Show or hide the component selector according to `fixedComponent()`.
   * @param {string} [productName] Product name. Defaults to the selected product.
   * @returns {string} The fixed component name, or an empty string if the user has to pick one.
   */
  static updateComponentSection(productName = this.productName) {
    const fixedComponent = this.fixedComponent(productName);

    this.$componentSection.hidden = !!fixedComponent;

    return fixedComponent;
  }

  /**
   * Set the currently selected product.
   * @param {string} productName Product name.
   */
  static async setProduct(productName) {
    if (productName === this.productName && this.details) {
      return;
    }

    // display the product name
    this.$product.value = productName;
    this.$productLabel.innerHTML = productName.htmlEncode();
    this.$dupeProductName.innerHTML = productName.htmlEncode();

    const { basepath } = BUGZILLA.config;
    const params = new URLSearchParams({ product: productName });

    this.$listComp.href = `${basepath}describecomponents.cgi?${params}`;

    GuidedBugEntry.setAdvancedLink();

    if (productName === '') {
      this.$support.hidden = true;
      return;
    }

    // show support message
    const { support } = products[productName] ?? {};

    if (support) {
      this.$supportMessage.innerHTML = support;
    }

    this.$support.hidden = !support;

    // show/hide component selection row
    this.updateComponentSection(productName);

    if (this.loadedProductName === productName) {
      return;
    }

    // grab the product information
    this.details = null;
    this.loadedProductName = productName;

    try {
      const { products } = await Bugzilla.API.get('product', {
        names: [productName],
        exclude_fields: ['internals', 'milestones', 'components.flag_types'],
      });

      if (products.length) {
        this.details = products[0];
        GuidedBugEntryFormPage.onProductUpdated();
      } else {
        document.location.href = `${basepath}enter_bug.cgi?format=guided`;
      }
    } catch (err) {
      this.loadedProductName = null;
      this.details = null;
      GuidedBugEntryFormPage.onProductUpdated();
      console.error(err);
      alert(`Failed to retrieve components for product "${productName}"\n\n${err.message}`);
    }
  }
}

/**
 * Other products selection page.
 */
class GuidedBugEntryOtherProductsPage {
  /**
   * Show callback.
   */
  static onShow() {
    GuidedBugEntry.updateSteppers('product');
  }
}

/**
 * Duplicate search page.
 */
class GuidedBugEntryOtherDupesPage {
  /**
   * Reference to the duplicate results data table.
   * @type {Bugzilla.DataTable}
   */
  static dataTable = null;

  /**
   * Data table columns.
   * @type {{ key: string, label: string , formatter: function, allowHTML: boolean, sortable:
   * boolean }[]}
   */
  static dataTableColumns = null;

  /**
   * Reference to the summary input element.
   * @type {HTMLInputElement}
   */
  static $summary = null;

  /**
   * Reference to the search button element.
   * @type {HTMLButtonElement}
   */
  static $search = null;

  /**
   * Reference to the duplicate list container element.
   * @type {HTMLDivElement}
   */
  static $list = null;

  /**
   * Reference to the “continue to the form” container element.
   * @type {HTMLDivElement}
   */
  static $continue = null;

  /**
   * Reference to the “continue to the form” button element.
   * @type {HTMLButtonElement}
   */
  static $continueButton = null;

  /**
   * Reference to the localization message element.
   * @type {HTMLElement}
   */
  static $l10nMessage = null;

  /**
   * Reference to the product name within the localization message.
   * @type {HTMLElement}
   */
  static $l10nProduct = null;

  /**
   * Reference to the localization message link element.
   * @type {HTMLAnchorElement}
   */
  static $l10nLink = null;

  /**
   * Current search query.
   * @type {string}
   */
  static currentSearchQuery = '';

  /**
   * Initialization callback.
   */
  static onInit() {
    this.$summary = document.querySelector('#dupe-summary');
    this.$search = document.querySelector('#dupe-search');
    this.$list = document.querySelector('#dupe-list');
    this.$continue = document.querySelector('#dupe-continue');
    this.$continueButton = document.querySelector('#dupe-continue-button');
    this.$l10nMessage = document.querySelector('#l10n-message');
    this.$l10nProduct = document.querySelector('#l10n-product');
    this.$l10nLink = document.querySelector('#l10n-link');

    this.$summary.addEventListener('blur', this.onSummaryBlur.bind(this));
    this.$summary.addEventListener('input', this.onSummaryBlur.bind(this));
    this.$summary.addEventListener('keydown', this.onSummaryKeyDown.bind(this));
    this.$summary.addEventListener('keyup', this.onSummaryKeyUp.bind(this));
    this.$search.addEventListener('click', this.doSearch.bind(this));
  }

  /**
   * Initialize the duplicate results data table.
   */
  static initDataTable() {
    const labels = JSON.parse(document.querySelector('#guided').dataset.dupeLabels);

    this.dataTableColumns = [
      { key: 'id', label: labels.id, formatter: this.formatId.bind(this), allowHTML: true },
      { key: 'summary', label: labels.summary },
      { key: 'component', label: labels.component },
      { key: 'status', label: labels.status, formatter: this.formatStatus.bind(this) },
      {
        key: 'update_token',
        label: 'Action',
        formatter: this.formatCc.bind(this),
        allowHTML: true,
        sortable: false,
      },
    ];

    this.dataTable = new Bugzilla.DataTable({
      container: '#dupe-list',
      columns: this.dataTableColumns,
      strings: {
        EMPTY: 'No similar issues found.',
        ERROR: 'An error occurred while searching for similar issues, please try again.',
      },
    });
  }

  /**
   * Format bug ID as a link.
   * @param {object} params Formatter parameters.
   * @param {number} params.value Bug ID.
   * @returns {string} Formatted HTML.
   */
  static formatId({ value: id }) {
    return `<a href="${BUGZILLA.config.basepath}show_bug.cgi?id=${id}" target="_blank">${id}</a>`;
  }

  /**
   * Format bug status with resolution.
   * @param {object} params Formatter parameters.
   * @param {string} params.value Bug status.
   * @param {object} params.data Bug data.
   * @param {string} params.data.resolution Bug resolution.
   * @returns {string} Formatted status.
   */
  static formatStatus({ value, data: { resolution } }) {
    const status = display_value('bug_status', value);
    return resolution ? `${status} ${display_value('resolution', resolution)}` : status;
  }

  /**
   * Format CC column with follow/unfollow button.
   * @param {object} params Formatter parameters.
   * @returns {string | HTMLButtonElement} Follow/unfollow button, or empty string if not
   * applicable.
   */
  static formatCc({ data: { id, status, cc } }) {
    return this.buildCcHTML(
      id,
      status,
      cc.some((email) => email === BUGZILLA.user.login),
    );
  }

  /**
   * Build the CC column HTML.
   * @param {number} id Bug ID.
   * @param {string} bugStatus Bug status.
   * @param {boolean} isCCed Whether the user is CCed.
   * @param {HTMLButtonElement} [button] Existing button element.
   * @returns {string | HTMLButtonElement} Button element or empty string.
   */
  static buildCcHTML(id, bugStatus, isCCed, button) {
    const isOpen = GuidedBugEntry.openStates.includes(bugStatus);

    if (!isOpen && !isCCed) {
      // you can’t cc yourself to a closed bug here
      return '';
    }

    button ??= document.createElement('button');
    button.type = 'button';
    button.disabled = false;

    if (isCCed) {
      button.innerHTML = 'Stop&nbsp;following';
      button.onclick = () => {
        this.updateFollowing(id, bugStatus, false, button);
        return false;
      };
    } else {
      button.innerHTML = 'Follow&nbsp;bug';
      button.onclick = () => {
        this.updateFollowing(id, bugStatus, true, button);
        return false;
      };
    }

    return button;
  }

  /**
   * Update following status for a bug.
   * @param {number} bugID Bug ID.
   * @param {string} bugStatus Bug status.
   * @param {boolean} follow Whether to follow or unfollow.
   * @param {HTMLButtonElement} button Button element.
   * @returns {Promise<string | HTMLButtonElement>} Updated button element.
   */
  static async updateFollowing(bugID, bugStatus, follow, button) {
    button.disabled = true;
    button.innerHTML = 'Updating...';

    const { login } = BUGZILLA.user;
    const ccObject = follow ? { add: [login] } : { remove: [login] };

    try {
      await Bugzilla.API.put(`bug/${bugID}`, { ids: [bugID], cc: ccObject });
      return this.buildCcHTML(bugID, bugStatus, follow, button);
    } catch ({ message }) {
      alert(`Update failed:\n\n${message}`);
      return this.buildCcHTML(bugID, bugStatus, !follow, button);
    }
  }

  /**
   * Reset the duplicate search page.
   */
  static reset() {
    this.$summary.value = '';
    this.$list.hidden = true;
    this.$list.innerHTML = '';
    this.$continue.hidden = true;
    this.currentSearchQuery = '';

    window.requestAnimationFrame(() => {
      this.$summary.focus();
      this.$summary.select();
    });
  }

  /**
   * Show callback.
   */
  static onShow() {
    this.onSummaryBlur();

    GuidedBugEntry.updateSteppers('dupes');

    const { productName } = GuidedBugEntryProductPage;

    if (products[productName]?.l10n) {
      this.$l10nProduct.textContent = productName;
      this.$l10nLink.onclick = (event) => {
        event.preventDefault();
        GuidedBugEntryProductPage.select('Mozilla Localizations');
      };
      this.$l10nMessage.hidden = false;
    } else {
      this.$l10nMessage.hidden = true;
    }

    if (!this.$search.disabled && this.summary.length >= 4) {
      // do an immediate search after a page refresh if there’s a query
      this.doSearch();
    } else {
      // prepare for a search
      this.reset();
    }
  }

  /**
   * Summary input blur handler.
   */
  static onSummaryBlur() {
    this.$search.disabled = !this.summary;
    GuidedBugEntry.setAdvancedLink();
  }

  /**
   * Summary input keydown handler.
   * @param {KeyboardEvent} event `keydown` event.
   */
  static onSummaryKeyDown(event) {
    // map <enter> to doSearch()
    if (event.keyCode === 13) {
      this.doSearch();
      event.stopPropagation();
    }
  }

  /**
   * Summary input keyup handler.
   */
  static onSummaryKeyUp() {
    // disable search button until there’s a query
    this.$search.disabled = !this.summary;
  }

  /**
   * Perform the duplicate search.
   */
  static async doSearch() {
    if ([...this.summary].length < 4) {
      GuidedBugEntry.setFieldError(this.$summary, 'The summary must be at least 4 characters.');

      return;
    }

    GuidedBugEntry.setFieldError(this.$summary);

    this.$search.blur();

    // don’t query if we already have the results (or they are pending)
    if (this.currentSearchQuery === this.summary) {
      return;
    }

    this.currentSearchQuery = this.summary;

    // initialize the datatable as late as possible
    this.initDataTable();

    try {
      // run the search
      this.$list.hidden = false;

      const src = `${BUGZILLA.config.basepath}extensions/GuidedBugEntry/web/images/throbber.gif`;

      this.dataTable.render([]);
      this.dataTable.setMessage(
        `Searching for similar issues...&nbsp;&nbsp;&nbsp;<img src="${src}" width="16" height="11">`,
      );

      this.$continueButton.disabled = true;
      this.$continue.hidden = false;

      let data;

      const includeFields = [
        'id',
        'summary',
        'status',
        'resolution',
        'update_token',
        'cc',
        'component',
      ];

      try {
        const { bugs } = await Bugzilla.API.get('bug/possible_duplicates', {
          product: GuidedBugEntryProductPage.productNameAndRelated,
          summary: this.summary,
          limit: 12,
          include_fields: includeFields,
        });

        data = { results: bugs };
      } catch (ex) {
        console.error(ex);
        this.currentSearchQuery = '';
        data = { error: true };
      }

      this.$continueButton.disabled = false;
      this.dataTable.update(data);
    } catch (err) {
      console.error(err.message);
    }
  }

  /**
   * Get the current summary value.
   */
  static get summary() {
    return this.$summary.value.trim();
  }
}

/**
 * Bug entry form page.
 */
class GuidedBugEntryFormPage {
  /**
   * Reference to the bug form element.
   * @type {HTMLFormElement}
   */
  static $form = null;

  /**
   * Reference to the submit button element.
   * @type {HTMLInputElement}
   */
  static $submitButton = null;

  /**
   * Reference to the short description input element.
   * @type {HTMLInputElement}
   */
  static $shortDescInput = null;

  /**
   * Reference to the hidden component input element.
   * @type {HTMLInputElement}
   */
  static $component = null;

  /**
   * Reference to the component select element.
   * @type {HTMLSelectElement}
   */
  static $componentSelect = null;

  /**
   * Reference to the component description element.
   * @type {HTMLDivElement}
   */
  static $componentDesc = null;

  /**
   * Reference to the hidden version input element.
   * @type {HTMLInputElement}
   */
  static $version = null;

  /**
   * Reference to the version select element.
   * @type {HTMLSelectElement}
   */
  static $versionSelect = null;

  /**
   * Reference to the version selection section element.
   * @type {HTMLElement}
   */
  static $versionSection = null;

  /**
   * Reference to the element the attachment selector is rendered into.
   * @type {HTMLElement}
   */
  static $attPlaceholder = null;

  /**
   * Reference to the attachment description section element.
   * @type {HTMLElement}
   */
  static $attDescSection = null;

  /**
   * Reference to the attachment description input element.
   * @type {HTMLInputElement}
   */
  static $attDescription = null;

  /**
   * Reference to the hidden attachment content type input element.
   * @type {HTMLInputElement}
   */
  static $attMimeType = null;

  /**
   * Reference to the hidden attachment patch flag input element.
   * @type {HTMLInputElement}
   */
  static $attIsPatch = null;

  /**
   * Reference to the currently visible help panel.
   * @type {HTMLElement}
   */
  static $visibleHelpPanel = null;

  /**
   * The attachment selector, created once the form page is first shown.
   * @type {Bugzilla.AttachmentSelector | undefined}
   */
  static attachmentSelector;

  /**
   * Whether the user has edited the attachment description themselves, in which case it’s no
   * longer updated automatically.
   * @type {boolean}
   */
  static attDescOverridden = false;

  /**
   * List of elements that are conditionally displayed.
   * @type {{ check: () => boolean, id: string }[]}
   */
  static conditionalDetails = [
    {
      check: () => GuidedBugEntryProductPage.productName === 'Firefox',
      id: 'firefox-android-row',
    },
  ];

  /**
   * Initialization callback.
   */
  static onInit() {
    this.$form = document.querySelector('#bug-form');
    this.$submitButton = document.querySelector('#submit-button');
    this.$shortDescInput = document.querySelector('#short-desc');
    this.$component = document.querySelector('#component');
    this.$componentSelect = document.querySelector('#component-select');
    this.$componentDesc = document.querySelector('#component-description');
    this.$version = document.querySelector('#version');
    this.$versionSelect = document.querySelector('#version-select');
    this.$versionSection = document.querySelector('#version-section');
    this.$attPlaceholder = document.querySelector('#att-placeholder');
    this.$attDescSection = document.querySelector('#att-desc-section');
    this.$attDescription = document.querySelector('#att-description');
    this.$attMimeType = document.querySelector('[name="contenttypeentry"]');
    this.$attIsPatch = document.querySelector('[name="ispatch"]');

    document.querySelector('#user_agent').value = navigator.userAgent;

    this.$shortDescInput.addEventListener('blur', () => {
      GuidedBugEntryOtherDupesPage.$summary.value = this.$shortDescInput.value;
      GuidedBugEntry.setAdvancedLink();
    });

    this.$form.addEventListener('submit', async (event) => this.submitForm(event));

    this.$versionSelect.addEventListener('change', (event) => {
      this.onVersionChange(event.target.value);
    });

    this.$componentSelect.addEventListener('change', (event) => {
      this.onComponentChange(event.target.value);
    });

    this.$attDescription.addEventListener('change', () => {
      this.attDescOverridden = true;
    });

    const useMarkdown = BUGZILLA.param.use_markdown;

    document.querySelectorAll('#bug-form textarea.description').forEach(($textarea) => {
      new Bugzilla.CommentEditor({ $textarea, useMarkdown, showTips: false }).render();
    });
  }

  /**
   * Show help tooltip.
   * @param {HTMLElement} $tooltip Tooltip element.
   * @param {HTMLElement} $icon Help icon element.
   */
  static showHelp($tooltip, $icon) {
    if (this.$visibleHelpPanel) {
      this.$visibleHelpPanel.hidden = true;
    }

    const { top, left } = $icon.getBoundingClientRect();

    $tooltip.style.inset = `${top + 24}px auto auto ${left - 320}px`;
    $tooltip.hidden = false;
    this.$visibleHelpPanel = $tooltip;
  }

  /**
   * Hide help tooltip.
   * @param {HTMLElement} $tooltip Tooltip element.
   */
  static hideHelp($tooltip) {
    $tooltip.hidden = true;
    this.$visibleHelpPanel = null;
  }

  /**
   * Initialize help tooltips.
   */
  static initHelp() {
    document.querySelectorAll('.help-trigger').forEach(($icon) => {
      const $tooltip = document.getElementById($icon.getAttribute('aria-describedby'));

      $icon.addEventListener('mouseover', () => {
        this.showHelp($tooltip, $icon);
      });

      $icon.addEventListener('mouseout', () => {
        this.hideHelp($tooltip);
      });

      $icon.addEventListener('focus', () => {
        this.showHelp($tooltip, $icon);
      });

      $icon.addEventListener('blur', () => {
        this.hideHelp($tooltip);
      });

      $icon.addEventListener('click', (event) => {
        event.preventDefault();
      });
    });
  }

  /**
   * Show callback.
   */
  static onShow() {
    // check for a forced format
    const productName = GuidedBugEntryProductPage.productName;
    const productSummary = GuidedBugEntryOtherDupesPage.summary;
    const { format } = products[productName] ?? {};

    if (format) {
      const params = new URLSearchParams({
        format,
        product: productName,
        short_desc: productSummary,
      });

      document.location.href = `${BUGZILLA.config.basepath}enter_bug.cgi?${params}`;
      GuidedBugEntry.updateStep = false;

      return;
    }

    // default the summary to the dupes query
    this.$shortDescInput.value = productSummary;
    this.resetSubmitButton();

    if (this.$componentSelect.length === 0) {
      this.onProductUpdated();
    }

    this.attachmentSelector ??= new Bugzilla.AttachmentSelector({
      $placeholder: this.$attPlaceholder,
      eventHandlers: {
        AttachmentProcessed: (event) => this.onAttachmentProcessed(event),
        AttachmentTextUpdated: (event) => this.onAttachmentTextUpdated(event),
      },
    });

    this.requiredFields.forEach(($field) => {
      GuidedBugEntry.setFieldError($field);
    });

    this.conditionalDetails.forEach((cond) => {
      document.getElementById(cond.id).hidden = !cond.check();
    });

    window.requestAnimationFrame(() => {
      this.$shortDescInput.focus();
      this.$shortDescInput.select();
    });

    GuidedBugEntry.updateSteppers('form');
  }

  /**
   * Called whenever a file is processed by `AttachmentSelector`. Update the Description, Content
   * Type, Patch checkbox, etc. based on the file properties and content.
   * @param {object} params An object with the following properties:
   * @param {File} params.file A processed `File` object.
   * @param {string} params.type A MIME type to be selected in the Content Type field.
   * @param {boolean} params.isPatch `true` if the file is detected as a patch, `false` otherwise.
   */
  static onAttachmentProcessed({ file, type, isPatch }) {
    this.$attDescSection.hidden = false;
    this.$attDescription.value = file.name;
    this.$attDescription.disabled = false;
    this.$attDescription.setAttribute('aria-required', true);
    this.$attMimeType.value = type;
    this.$attIsPatch.value = isPatch ? 'on' : '';
  }

  /**
   * Called whenever the attachment text is updated. Update the Content Type, Patch checkbox, etc.
   * based on the new content.
   * @param {object} params An object with the following properties:
   * @param {string} params.text The new text content.
   * @param {boolean} params.hasText `true` if the textarea has non-empty content, `false`
   * otherwise.
   * @param {boolean} params.isPatch `true` if the content is detected as a patch, `false`
   * otherwise.
   * @param {boolean} params.isGhpr `true` if the content is detected as a GitHub Pull Request link,
   * `false` otherwise.
   */
  static onAttachmentTextUpdated({ text, hasText, isPatch, isGhpr }) {
    if (!this.attDescOverridden) {
      this.$attDescription.value = isPatch ? 'patch' : isGhpr ? 'GitHub Pull Request' : '';
    }

    this.$attDescSection.hidden = !hasText;
    this.$attDescription.disabled = !hasText;
    this.$attDescription.setAttribute('aria-required', hasText);
    this.$attMimeType.value = isGhpr ? 'text/x-github-pull-request' : 'text/plain';
    this.$attIsPatch.value = isPatch ? 'on' : '';

    if (!hasText) {
      this.attDescOverridden = false;
    }
  }

  /**
   * Reset the submit button state.
   */
  static resetSubmitButton() {
    this.$submitButton.disabled = false;
    this.$submitButton.value = 'Submit Bug';
  }

  /**
   * Escape special characters for use in a regex.
   * @param {string} value Input string.
   * @returns {string} Escaped string.
   */
  static quoteMeta(value) {
    return value.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&');
  }

  /**
   * Clear the currently selected component. Called when the user picks a product, so the component
   * chosen for the previously selected product isn’t silently reused.
   */
  static resetComponent() {
    this.$component.value = '';
    this.$componentDesc.innerHTML = '';
    this.$componentDesc.hidden = true;
  }

  /**
   * Product updated callback.
   */
  static onProductUpdated() {
    const productName = GuidedBugEntryProductPage.productName;

    // init
    const $components = this.$componentSelect;
    const $versions = this.$versionSelect;

    this.$componentDesc.hidden = true;
    $components.options.length = 0;
    $versions.options.length = 0;

    // product not loaded yet, bail out
    if (!GuidedBugEntryProductPage.details) {
      this.$submitButton.disabled = true;

      return;
    }

    this.$submitButton.disabled = false;

    const { componentFilter, defaultComponent } = products[productName] ?? {};
    const fixedComponent = GuidedBugEntryProductPage.updateComponentSection(productName);

    // filter components
    if (componentFilter) {
      GuidedBugEntryProductPage.details.components = componentFilter(
        GuidedBugEntryProductPage.details.components,
      );
    }

    // build components
    if (fixedComponent) {
      this.$component.value = fixedComponent;
      this.$componentSelect.removeAttribute('aria-required');
    } else {
      this.$componentSelect.setAttribute('aria-required', 'true');

      const { preselectedComponent } = GuidedBugEntryProductPage;

      // check for the default component
      const defaultRegex = preselectedComponent
        ? new RegExp(`^${this.quoteMeta(preselectedComponent)}$`, 'i')
        : defaultComponent
          ? new RegExp(`^${this.quoteMeta(defaultComponent)}$`, 'i')
          : new RegExp('General', 'i');

      const { components } = GuidedBugEntryProductPage.details;
      const component = components.find((c) => c.is_active && defaultRegex.test(c.name));
      const preselectedComponentName = component?.name ?? null;

      // if there isn’t a default component, default to blank
      if (!preselectedComponentName) {
        $components.options.add(new Option('', ''));
      }

      // build component select
      components.forEach((c) => {
        if (c.is_active) {
          $components.options.add(new Option(c.name, c.name));
        }
      });

      const validComponent = [...$components.options].some(
        (o) => o.value === this.$component.value,
      );

      if (!validComponent) {
        this.$component.value = '';
      }

      if (this.$component.value === '' && preselectedComponentName) {
        this.$component.value = preselectedComponentName;
      }

      if (this.$component.value !== '') {
        $components.value = this.$component.value;
        this.onComponentChange(this.$component.value);
      }
    }

    // build versions
    const currentVersion = this.$version.value;
    let defaultVersion = '';

    GuidedBugEntryProductPage.details.versions.forEach(({ is_active, name }) => {
      if (is_active) {
        $versions.options.add(new Option(name, name));

        if (currentVersion === name) {
          defaultVersion = name;
        }
      }
    });

    if (!defaultVersion) {
      // try to detect version on a per-product basis
      if (products[productName]?.version) {
        const detectedVersion = products[productName].version();

        if ([...$versions.options].some((o) => o.value === detectedVersion)) {
          defaultVersion = detectedVersion;
        }
      }
    }

    // If there’s only one version, we don’t need to ask the user
    const singleVersion = $versions.length <= 1;

    this.$versionSection.hidden = singleVersion;

    if (singleVersion) {
      defaultVersion = $versions.options[0]?.value;
    }

    if (defaultVersion) {
      $versions.value = defaultVersion;
    } else if ([...$versions.options].some((o) => o.value === 'unspecified')) {
      // Fallback to 'unspecified' if available
      $versions.value = 'unspecified';
    } else {
      // No default version, select an empty value to force a decision
      $versions.options.add(new Option('', ''), $versions.options[0]);
      $versions.value = '';
    }

    this.onVersionChange($versions.value);

    // Set default Platform, OS and Security Group
    // Skip if the default value is empty = auto-detect
    const { default_platform, default_op_sys, default_security_group } =
      GuidedBugEntryProductPage.details;

    if (default_platform) {
      document.querySelector('#rep_platform').value = default_platform;
    }

    if (default_op_sys) {
      document.querySelector('#op_sys').value = default_op_sys;
    }

    if (default_security_group) {
      document.querySelector('#groups').value = default_security_group;
    }
  }

  /**
   * Component change handler. Sets the hidden component input and shows the description.
   * @param {string} componentName Component name.
   */
  static onComponentChange(componentName) {
    this.$component.value = componentName;

    const component = GuidedBugEntryProductPage.details.components.find(
      (c) => c.name === componentName,
    );

    this.$componentDesc.innerHTML = component?.description ?? '';
    this.$componentDesc.hidden = false;
  }

  /**
   * Version change handler. Sets the hidden version input.
   * @param {string} version Version name.
   */
  static onVersionChange(version) {
    this.$version.value = version;
  }

  /**
   * Get all required fields in the form.
   * @returns {HTMLElement[]} Array of required field elements.
   */
  static get requiredFields() {
    // Only the field’s own `<section>` decides whether it’s reachable. Don’t look at every
    // ancestor: the comment editor hides its edit tabpanel while the Preview tab is selected, and
    // the field inside it still has to be validated.
    return [...this.$form.querySelectorAll('[aria-required="true"]')].filter(
      ($field) => !$field.closest('section')?.hidden,
    );
  }

  /**
   * Check for missing required fields.
   * @returns {string[]} Array of IDs of missing required fields.
   */
  static checkMissing() {
    /** @type {string[]} */
    const result = [];

    this.requiredFields.forEach(($field) => {
      const invalid =
        $field.getAttribute('role') === 'radiogroup'
          ? ![...$field.querySelectorAll('input')].some((r) => r.checked)
          : !$field.value.trim();

      if (!invalid) {
        GuidedBugEntry.setFieldError($field);

        return;
      }

      const message = $field.matches('[role="radiogroup"], select')
        ? 'Please select an option.'
        : $field.matches('[data-allow-na]')
          ? 'This field is required. Write “N/A” if not applicable.'
          : 'This field is required.';

      GuidedBugEntry.setFieldError($field, message);
      result.push($field.id);
    });

    return result;
  }

  /**
   * Validate the form before submission.
   * @returns {boolean} Whether the form is valid for submission.
   */
  static validate() {
    const missing = this.checkMissing();

    if (missing.length) {
      document.getElementById(missing[0])?.focus();
      return false;
    }

    return true;
  }

  /**
   * Submit the bug form.
   */
  static async submitForm(event) {
    // The attachment selector can cancel the submission from its own `submit` listener, which runs
    // after this one, so ask it first: the submit button must not be left disabled in that case
    const attachmentValid = this.attachmentSelector?.validate(event) ?? true;

    if (!this.validate() || !attachmentValid) {
      event.preventDefault();

      return false;
    }

    this.$submitButton.disabled = true;
    this.$submitButton.value = 'Submitting Bug...';

    return true;
  }
}

window.addEventListener('DOMContentLoaded', () => {
  GuidedBugEntry.init();
});
