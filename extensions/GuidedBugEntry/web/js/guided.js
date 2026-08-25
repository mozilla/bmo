/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

// global

var guided = {
  _currentStep: '',
  _defaultStep: 'product',
  currentUser: '',
  openStates: [],
  updateStep: true,

  setStep: function(newStep, noSetHistory) {
    // initialize new step
    this.updateStep = true;
    switch(newStep) {
      case 'webdev':
        webdev.onShow();
        break;
      case 'product':
        product.onShow();
        break;
      case 'otherProducts':
        otherProducts.onShow();
        break;
      case 'dupes':
        dupes.onShow();
        break;
      case 'bugForm':
        bugForm.onShow();
        break;
      default:
        guided.setStep(this._defaultStep);
        return;
    }

    if (!this.updateStep)
        return;

    // change visibility of _step div
    if (this._currentStep)
      document.getElementById(`${this._currentStep}_step`).classList.add('hidden');
    this._currentStep = newStep;
    document.getElementById(`${this._currentStep}_step`).classList.remove('hidden');

    // scroll to top of page to mimic real navigation
    scroll(0,0);

    // update history
    if (!noSetHistory) {
      const params = new URLSearchParams(window.location.search);
      const isDefaultStep = newStep === this._defaultStep;
      const _product = isDefaultStep ? '' : product.getName();
      const _component = isDefaultStep ? '' : product.getPreselectedComponent();

      if (_product) {
        params.set('product', _product);
      } else {
        params.delete('product');
      }

      if (_component) {
        params.set('component', _component);
      } else {
        params.delete('component');
      }

      window.history.pushState(
        {
          step: newStep,
          product: _product,
          component: _component,
        },
        '',
        `${window.location.pathname}?${params.toString()}`
      );
    }
  },

  init: function(conf) {
    // init history manager
    if (conf.webdev) {
      this._defaultStep = 'webdev';
      this.webdev = true;
    }

    // init steps
    webdev.onInit();
    product.onInit();
    dupes.onInit();
    bugForm.onInit();
    bugForm.initHelp();

    const noSetHistory = !window.history.state;

    if (!window.history.state) {
      const params = new URLSearchParams(window.location.search);
      // Support for the legacy, hash-based YUI history state handler
      const [_step = '', _product = '', _component = '']
        = window.location.hash.replace('#h=', '').split('|').map(str => decodeURIComponent(str));

      if (_product) {
        params.set('product', _product);
      }

      if (_component) {
        params.set('component', _component);
      }

      const _params = Object.fromEntries(params);

      window.history.replaceState(
        {
          step: _step || (_params.product ? 'dupes' : this._defaultStep),
          product: _params.product || '',
          component: _params.component || '',
        },
        '',
        `${window.location.pathname}?${params.toString()}`
      );
    }

    this._onStateChange(noSetHistory);

    window.addEventListener('popstate', () => {
      this._onStateChange(true);
    });
  },

  _onStateChange: function(noSetHistory) {
    const state = window.history.state ?? {};

    product.setName(state.product ?? '');
    product.setPreselectedComponent(state.component ?? '');
    guided.setStep(state.step, noSetHistory);
  },

  setAdvancedLink: function() {
    var href = `${BUGZILLA.config.basepath}enter_bug.cgi?format=__default__` +
               `&product=${encodeURIComponent(product.getName())}` +
               `&short_desc=${encodeURIComponent(dupes.getSummary())}`;
    document.getElementById('advanced_img').href = href;
    document.getElementById('advanced_link').href = href;
  }
};

// webdev step

var webdev = {
    details: false,

    onInit: function () { },

    onShow: function () { }
};

// product step

var product = {
  details: false,
  _loaded: '',
  _preselectedComponent: '',

  onInit: function() { },

  onShow: function() {
    document.getElementById('advanced').classList.remove('hidden');
  },

  select: function(productName, componentName) {
    var prod = products[productName];

    // called when a product is selected
    if (componentName) {
      if (prod && prod.defaultComponent) {
        prod.originalDefaultComponent = prod.originalDefaultComponent || prod.defaultComponent;
        prod.defaultComponent = componentName;
      }
    }
    else {
      if (prod && prod.defaultComponent && prod.originalDefaultComponent) {
        prod.defaultComponent = prod.originalDefaultComponent;
      }
    }
    this.setPreselectedComponent(prod?.defaultComponent || '');
    this.setName(productName);
    dupes.reset();
    guided.setStep('dupes');
  },

  getName: function() {
    return document.getElementById('product').value;
  },

  getPreselectedComponent: function() {
    return this._preselectedComponent;
  },

  setPreselectedComponent: function(value) {
    this._preselectedComponent = value;
  },

  _getNameAndRelated: function() {
    var result = [];

    var name = this.getName();
    result.push(name);

    if (products[name] && products[name].related) {
      for (var i = 0, n = products[name].related.length; i < n; i++) {
        result.push(products[name].related[i]);
      }
    }

    return result;
  },

  setName: async function(productName) {
    if (productName == this.getName() && this.details)
      return;

    // display the product name
    document.getElementById('product').value = productName;
    document.getElementById('product_label').innerHTML = productName.htmlEncode();
    document.getElementById('dupes_product_name').innerHTML = productName.htmlEncode();
    document.getElementById('list_comp').href
      = `${BUGZILLA.config.basepath}describecomponents.cgi?product=${encodeURIComponent(productName)}`;
    guided.setAdvancedLink();

    if (productName == '') {
      document.getElementById('product_support').classList.add('hidden');
      return;
    }

    // show support message
    if (products[productName] && products[productName].support) {
      document.getElementById('product_support_message').innerHTML = products[productName].support;
      document.getElementById('product_support').classList.remove('hidden');
    } else {
      document.getElementById('product_support').classList.add('hidden');
    }

    // show/hide component selection row
    const $row = document.getElementById('componentTR');
    if (products[productName] && products[productName].noComponentSelection || guided.webdev) {
      $row.classList.add('hidden');
    } else {
      $row.classList.remove('hidden');
    }

    if (this._loaded == productName)
      return;

    // grab the product information
    this.details = false;
    this._loaded = productName;

    try {
      const { products } = await Bugzilla.API.get('product', {
        names: [productName],
        exclude_fields: ['internals', 'milestones', 'components.flag_types'],
      });

      if (products.length) {
        product.details = products[0];
        bugForm.onProductUpdated();
      } else {
        document.location.href = `${BUGZILLA.config.basepath}enter_bug.cgi?format=guided`;
      }
    } catch ({ message }) {
      this._loaded = '';
      product.details = false;
      bugForm.onProductUpdated();
      alert(`Failed to retrieve components for product "${productName}"\n\n${message}`);
    }
  }
};

// other products step

var otherProducts = {
  onInit: function() { },

  onShow: function() {
    document.getElementById('advanced').classList.remove('hidden');
  }
};

// duplicates step

var dupes = {
  _dataTable: null,
  _dataTableColumns: null,
  _elSummary: null,
  _elSearch: null,
  _elList: null,
  _currentSearchQuery: '',

  onInit: function() {
    this._elSummary = document.getElementById('dupes_summary');
    this._elSearch = document.getElementById('dupes_search');
    this._elList = document.getElementById('dupes_list');

    this._elSummary.addEventListener('blur', this._onSummaryBlur);
    this._elSummary.addEventListener('input', this._onSummaryBlur);
    this._elSummary.addEventListener('keydown', this._onSummaryKeyDown);
    this._elSummary.addEventListener('keyup', this._onSummaryKeyUp);
    this._elSearch.addEventListener('click', this._doSearch);
  },

  setLabels: function(labels) {
    this._dataTableColumns = [
      { key: "id", label: labels.id, formatter: this._formatId, allowHTML: true },
      { key: "summary", label: labels.summary },
      { key: "component", label: labels.component },
      { key: "status", label: labels.status, formatter: this._formatStatus },
      { key: "update_token", label: '', formatter: this._formatCc, allowHTML: true, sortable: false }
    ];
  },

  _initDataTable: function() {
    this._dataTable = new Bugzilla.DataTable({
      container: '#dupes_list',
      columns: this._dataTableColumns,
      strings: {
        EMPTY: 'No similar issues found.',
        ERROR: 'An error occurred while searching for similar issues, please try again.'
      }
    });
  },

  _formatId: function({ value }) {
    return `<a href="${BUGZILLA.config.basepath}show_bug.cgi?id=${value}" target="_blank">${value}</a>`;
  },

  _formatStatus: function({ value, data: { resolution } }) {
    const status = display_value('bug_status', value);
    return resolution ? `${status} ${display_value('resolution', resolution)}` : status;
  },

  _formatCc: function({ data: { id, status, cc } }) {
    return dupes._buildCcHTML(id, status, cc.some((email) => email === guided.currentUser));
  },

  _buildCcHTML: function(id, bugStatus, isCCed, button) {
    const isOpen = guided.openStates.includes(bugStatus);

    if (!isOpen && !isCCed) {
      // you can't cc yourself to a closed bug here
      return '';
    }

    button ||= document.createElement('button');
    button.type = 'button';
    button.disabled = false;

    if (isCCed) {
      button.innerHTML = 'Stop&nbsp;following';
      button.onclick = () => {
        dupes.updateFollowing(id, bugStatus, false, button); return false;
      };
    } else {
      button.innerHTML = 'Follow&nbsp;bug';
      button.onclick = () => {
        dupes.updateFollowing(id, bugStatus, true, button); return false;
      };
    }

    return button;
  },

  updateFollowing: async function(bugID, bugStatus, follow, button) {
    button.disabled = true;
    button.innerHTML = 'Updating...';

    var ccObject;
    if (follow) {
      ccObject = { add: [ guided.currentUser ] };
    } else {
      ccObject = { remove: [ guided.currentUser ] };
    }

    try {
      await Bugzilla.API.put(`bug/${bugID}`, { ids: [bugID], cc: ccObject });
      return dupes._buildCcHTML(bugID, bugStatus, follow, button);
    } catch ({ message }) {
      alert(`Update failed:\n\n${message}`);
      return dupes._buildCcHTML(bugID, bugStatus, !follow, button);
    }
  },

  reset: function() {
    this._elSummary.value = '';
    this._elList.classList.add('hidden');
    document.getElementById('dupes_continue').classList.add('hidden');
    this._elList.innerHTML = '';
    this._showProductSupport();
    this._currentSearchQuery = '';
    this._elSummary.focus();
  },

  _showProductSupport: function() {
    const elSupportId = `product_support_${product.getName().replace(' ', '_').toLowerCase()}`;
    document.querySelectorAll('.product_support').forEach(($element) => {
      $element.classList.toggle('hidden', $element.id !== elSupportId);
    });
  },

  onShow: function() {
    this._showProductSupport();
    this._onSummaryBlur();

    // hide the advanced form and top continue button entry until
    // a search has happened
    document.getElementById('advanced').classList.add('hidden');
    document.getElementById('dupes_continue_button_top').classList.add('hidden');
    var prod = product.getName();
    if (products[prod] && products[prod].l10n) {
      document.getElementById('l10n_message').classList.remove('hidden');
      document.getElementById('l10n_product').textContent = product.getName();
      document.getElementById('l10n_link').onclick = function () {
        product.select('Mozilla Localizations');
      };
    }
    else {
      document.getElementById('l10n_message').classList.add('hidden');
    }

    if (!this._elSearch.disabled && this.getSummary().length >= 4) {
      // do an immediate search after a page refresh if there's a query
      this._doSearch();

    } else {
      // prepare for a search
      this.reset();
    }
  },

  _onSummaryBlur: function() {
    dupes._elSearch.disabled = dupes._elSummary.value == '';
    guided.setAdvancedLink();
  },

  _onSummaryKeyDown: function(e) {
    // map <enter> to doSearch()
    if (e && (e.keyCode == 13)) {
      dupes._doSearch();
      e.stopPropagation();
    }
  },

  _onSummaryKeyUp: function(e) {
    // disable search button until there's a query
    dupes._elSearch.disabled = dupes._elSummary.value.trim() == '';
  },

  _doSearch: async function() {
    if (dupes.getSummary().length < 4) {
      alert('The summary must be at least 4 characters long.');
      return;
    }
    dupes._elSummary.blur();

    // don't query if we already have the results (or they are pending)
    if (dupes._currentSearchQuery == dupes.getSummary())
      return;
    dupes._currentSearchQuery = dupes.getSummary();

    // initialize the datatable as late as possible
    dupes._initDataTable();

    try {
      // run the search
      dupes._elList.classList.remove('hidden');

      dupes._dataTable.render([]);
      dupes._dataTable.setMessage(
        'Searching for similar issues...&nbsp;&nbsp;&nbsp;' +
        `<img src="${BUGZILLA.config.basepath}extensions/GuidedBugEntry/web/images/throbber.gif"` +
        ' width="16" height="11">'
      );

      document.getElementById('dupes_continue_button_top').disabled = true;
      document.getElementById('dupes_continue_button_bottom').disabled = true;
      document.getElementById('dupes_continue').classList.remove('hidden');

      let data;

      try {
        const { bugs } = await Bugzilla.API.get('bug/possible_duplicates', {
          product: product._getNameAndRelated(),
          summary: dupes.getSummary(),
          limit: 12,
          include_fields: ['id', 'summary', 'status', 'resolution', 'update_token', 'cc', 'component'],
        });

        data = { results: bugs };
      } catch (ex) {
        dupes._currentSearchQuery = '';
        data = { error: true };
      }

      document.getElementById('advanced').classList.remove('hidden');
      document.getElementById('dupes_continue_button_top').classList.remove('hidden');
      document.getElementById('dupes_continue_button_top').disabled = false;
      document.getElementById('dupes_continue_button_bottom').disabled = false;
      dupes._dataTable.update(data);
    } catch(err) {
      if (console)
        console.error(err.message);
    }
  },

  getSummary: function() {
    var summary = this._elSummary.value.trim();
    // work around chrome bug
    if (summary == dupes._elSummary.getAttribute('placeholder')) {
      return '';
    } else {
      return summary;
    }
  }
};

// bug form step

var bugForm = {
  _visibleHelpPanel: null,
  _mandatoryFields: [],
  _conditionalDetails: [
    { check: function () { return product.getName() == 'Firefox'; }, id: 'firefox_for_android_row' }
  ],

  onInit: function() {
    var user_agent = navigator.userAgent;
    document.getElementById('user_agent').value = navigator.userAgent;
    document.getElementById('short_desc').addEventListener('blur', () => {
      document.getElementById('dupes_summary').value = document.getElementById('short_desc').value;
      guided.setAdvancedLink();
    });
  },

  initHelp: function() {
    document.querySelectorAll('.help_icon').forEach(($icon) => {
      const $tooltip = document.getElementById($icon.getAttribute('aria-describedby'));

      $icon.addEventListener('mouseover', () => {
        if (this._visibleHelpPanel) {
          this._visibleHelpPanel.hidden = true;
        }

        const { top, left } = $icon.getBoundingClientRect();

        $tooltip.style.inset = `${top}px auto auto ${left + 24}px`;
        $tooltip.hidden = false;
        this._visibleHelpPanel = $tooltip;
      });

      $icon.addEventListener('mouseout', () => {
        $tooltip.hidden = true;
        this._visibleHelpPanel = null;
      });
    });
  },

  onShow: function() {
    // check for a forced format
    var productName = product.getName();
    var visibleCount = 0;
    if (products[productName] && products[productName].format) {
        document.getElementById('advanced').classList.add('hidden');
        document.location.href = `${BUGZILLA.config.basepath}enter_bug.cgi?` +
                                 `format=${encodeURIComponent(products[productName].format)}` +
                                 `&product=${encodeURIComponent(productName)}` +
                                 `&short_desc=${encodeURIComponent(dupes.getSummary())}`;
        guided.updateStep = false;
        return;
    }
    document.getElementById('advanced').classList.remove('hidden');
    // default the summary to the dupes query
    document.getElementById('short_desc').value = dupes.getSummary();
    this.resetSubmitButton();
    if (document.getElementById('component_select').length == 0)
      this.onProductUpdated();
    this.initAttachmentSection();
    this._mandatoryFields.forEach((id) => {
      document.getElementById(id).classList.remove('missing');
    });

    this._conditionalDetails.forEach(function (cond) {
      if (cond.check()) {
        visibleCount++;
        document.getElementById(cond.id).classList.remove('hidden');
      }
      else {
        document.getElementById(cond.id).classList.add('hidden');
      }
    });
    if (visibleCount > 0) {
      document.getElementById('details').classList.remove('hidden');
      document.getElementById('submitTR').classList.remove('even');
    }
    else {
      document.getElementById('details').classList.add('hidden');
      document.getElementById('submitTR').classList.add('even');
    }
  },

  resetSubmitButton: function() {
    document.getElementById('submit').disabled = false;
    document.getElementById('submit').value = 'Submit Bug';
  },

  onProductUpdated: function() {
    var productName = product.getName();

    // init
    var elComponents = document.getElementById('component_select');
    document.getElementById('component_description').classList.add('hidden');
    elComponents.options.length = 0;

    var elVersions = document.getElementById('version_select');
    elVersions.length = 0;

    // product not loaded yet, bail out
    if (!product.details) {
      document.getElementById('versionTD').classList.add('hidden');
      document.getElementById('productTD').colSpan = 2;
      document.getElementById('submit').disabled = true;
      return;
    }
    document.getElementById('submit').disabled = false;

    // filter components
    if (products[productName] && products[productName].componentFilter) {
        product.details.components = products[productName].componentFilter(product.details.components);
    }

    // build components

    var elComponent = document.getElementById('component');
    if (products[productName] && products[productName].noComponentSelection || guided.webdev) {
      elComponent.value = products[productName].defaultComponent;
      bugForm._mandatoryFields = [ 'short_desc', 'version_select' ];
    } else {
      bugForm._mandatoryFields = [ 'short_desc', 'component_select', 'version_select' ];

      // check for the default component
      var defaultRegex;
      if (product.getPreselectedComponent()) {
        defaultRegex = new RegExp('^' + quoteMeta(product.getPreselectedComponent()) + '$', 'i');
      } else if(products[productName] && products[productName].defaultComponent) {
        defaultRegex = new RegExp('^' + quoteMeta(products[productName].defaultComponent) + '$', 'i');
      } else {
        defaultRegex = new RegExp('General', 'i');
      }

      var preselectedComponent = false;
      var i, n;
      var component;
      for (i = 0, n = product.details.components.length; i < n; i++) {
        component = product.details.components[i];
        if (component.is_active == '1') {
          if (defaultRegex.test(component.name)) {
            preselectedComponent = component.name;
            break;
          }
        }
      }

      // if there isn't a default component, default to blank
      if (!preselectedComponent) {
        elComponents.options[elComponents.options.length] = new Option('', '');
      }

      // build component select
      for (i = 0, n = product.details.components.length; i < n; i++) {
        component = product.details.components[i];
        if (component.is_active == '1') {
          elComponents.options[elComponents.options.length] =
            new Option(component.name, component.name);
        }
      }

      var validComponent = false;
      for (i = 0, n = elComponents.options.length; i < n && !validComponent; i++) {
        if (elComponents.options[i].value == elComponent.value)
          validComponent = true;
      }
      if (!validComponent)
        elComponent.value = '';
      if (elComponent.value == '' && preselectedComponent)
        elComponent.value = preselectedComponent;
      if (elComponent.value != '') {
        elComponents.value = elComponent.value;
        this.onComponentChange(elComponent.value);
      }

    }

    // build versions
    var defaultVersion = '';
    var currentVersion = document.getElementById('version').value;
    for (i = 0, n = product.details.versions.length; i < n; i++) {
      var version = product.details.versions[i];
      if (version.is_active == '1') {
        elVersions.options[elVersions.options.length] =
          new Option(version.name, version.name);
        if (currentVersion == version.name)
          defaultVersion = version.name;
      }
    }

    if (!defaultVersion) {
      // try to detect version on a per-product basis
      if (products[productName] && products[productName].version) {
        var detectedVersion = products[productName].version();
        var options = elVersions.options;
        for (i = 0, n = options.length; i < n; i++) {
          if (options[i].value == detectedVersion) {
            defaultVersion = detectedVersion;
            break;
          }
        }
      }
    }

    if (elVersions.length > 1) {
      // more than one version, show select
      document.getElementById('productTD').colSpan = 1;
      document.getElementById('versionTD').classList.remove('hidden');

    } else {
      // if there's only one version, we don't need to ask the user
      document.getElementById('versionTD').classList.add('hidden');
      document.getElementById('productTD').colSpan = 2;
      defaultVersion = elVersions.options[0].value;
    }

    if (defaultVersion) {
      elVersions.value = defaultVersion;

    } else {
      // no default version, select an empty value to force a decision
      var opt = new Option('', '');
      try {
        // standards
        elVersions.add(opt, elVersions.options[0]);
      } catch(ex) {
        // IE only
        elVersions.add(opt, 0);
      }
      elVersions.value = '';
    }
    bugForm.onVersionChange(elVersions.value);

    // Set default Platform, OS and Security Group
    // Skip if the default value is empty = auto-detect
    const { default_platform, default_op_sys, default_security_group } = product.details;

    if (default_platform) {
      document.querySelector('#rep_platform').value = default_platform;
    }

    if (default_op_sys) {
      document.querySelector('#op_sys').value = default_op_sys;
    }

    if (default_security_group) {
      document.querySelector('#groups').value = default_security_group;
    }
  },

  onComponentChange: function(componentName) {
    // show the component description
    document.getElementById('component').value = componentName;
    var elComponentDesc = document.getElementById('component_description');
    elComponentDesc.innerHTML = '';
    for (var i = 0, n = product.details.components.length; i < n; i++) {
      var component = product.details.components[i];
      if (component.name == componentName) {
        elComponentDesc.innerHTML = component.description;
        break;
      }
    }
    elComponentDesc.classList.remove('hidden');
  },

  onVersionChange: function(version) {
    document.getElementById('version').value = version;
  },

  initAttachmentSection: function() {
    // Hide expert parts of the attachment form for guided
    var elements = [...document.querySelectorAll('.expert_fields')];
    for (var i = 0; i < elements.length; i++) {
        elements[i].classList.add('bz_tui_hidden');
    }

    const $form = document.querySelector('#bugform');
    const $attachNewFile = document.querySelector('#attach-new-file');
    const $attachFileContentOuter = document.querySelector('#attach-file-content-outer');
    const $attachNoFile = document.querySelector('#attach-no-file');
    const $attachFileActionOuter = document.querySelector('#attach-file-action-outer');

    const updatedRequiredFields = (required) => {
      $attachFileContentOuter.querySelectorAll('[aria-required]').forEach(($input) => {
        $input.setAttribute('aria-required', required);
      });
    };

    $attachNewFile.addEventListener('click', () => {
      $attachFileActionOuter.hidden = true;
      $attachFileContentOuter.hidden = false;
      updatedRequiredFields(true);
    });

    $attachNoFile.addEventListener('click', () => {
      $attachFileActionOuter.hidden = false;
      $attachFileContentOuter.hidden = true;

      // Reset all the input values under Attachment
      $form.attach_text.value = '';
      $form.description.value = '';
      $form.ispatch.checked = false;
      $form.hide_preview.checked = false;
      $form.contenttypemethod.checked = true;
      $form.contenttypeselection.selectedIndex = 0;
      $form.contenttypeentry.value = '';
      document.querySelectorAll('#attachment_flags select').forEach(($select) => {
        $select.selectedIndex = 0;
      });
      updatedRequiredFields(false);
    });

    updatedRequiredFields(false);
  },

  _getFilename: function() {
    var filename = document.getElementById('data').value;
    if (!filename)
      return '';
    filename = filename.replace(/^.+[\\\/]/, '');
    return filename;
  },

  _mandatoryMissing: function() {
    var result = new Array();
    for (var i = 0, n = this._mandatoryFields.length; i < n; i++ ) {
      var id = this._mandatoryFields[i];
      var el = document.getElementById(id);
      var value;

      if (el.type.toString() == "checkbox") {
        value = el.checked;
      } else {
        value = el.value.replace(/^\s\s*/, '').replace(/\s\s*$/, '');
        el.value = value;
      }

      if (value == '') {
        document.getElementById(id).classList.add('missing');
        result.push(id);
      } else {
        document.getElementById(id).classList.remove('missing');
      }
    }
    return result;
  },

  validate: function() {

    // check mandatory fields

    var missing = bugForm._mandatoryMissing();
    if (missing.length) {
      var message = 'The following field' +
        (missing.length == 1 ? ' is' : 's are') + ' required:\n\n';
      for (var i = 0, n = missing.length; i < n; i++ ) {
        var id = missing[i];
        if (id == 'short_desc')       message += '  Summary\n';
        if (id == 'component_select') message += '  Component\n';
        if (id == 'version_select')   message += '  Version\n';
      }
      alert(message);
      return false;
    }

    if (document.getElementById('data').value && !document.getElementById('data_description').value)
      document.getElementById('data_description').value = bugForm._getFilename();

    document.getElementById('submit').disabled = true;
    document.getElementById('submit').value = 'Submitting Bug...';

    return true;
  },
};

function quoteMeta(value) {
  return value.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, "\\$&");
}
