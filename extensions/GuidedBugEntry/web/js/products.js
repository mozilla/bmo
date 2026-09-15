/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0. */

/* Product-specific configuration for guided bug entry
 *
 * related: array of product names which will also be searched for duplicates
 * version: function which returns a version (e.g. detected from UserAgent)
 * defaultComponent: the default component to select.  Defaults to 'General'
 * noComponentSelection: when true, the default component will always be
 *     used.  Defaults to 'false';
 * l10n: allow selecting Localization product
 * support: string which is displayed at the top of the duplicates page
 */

const products = {
  'addons.mozilla.org': {
    l10n: true,
  },

  Firefox: {
    related: ['Core', 'Toolkit'],
    version: () => {
      const re = /Firefox\/(?<major>\d+)\.(?<minor>\d+)/i;
      const groups = navigator.userAgent.match(re)?.groups;
      if (groups) {
        const { major, minor } = groups;
        if (major * 1 >= 80) {
          return 'Firefox ' + major;
        } else if (major * 1 >= 5) {
          return `${major} Branch`;
        } else {
          return `${major}.${minor} Branch`;
        }
      }
      return false;
    },
    defaultComponent: 'Untriaged',
    noComponentSelection: true,
    l10n: true,
    support:
      'If you are new to Firefox or Bugzilla, please consider checking ' +
      '<a href="https://support.mozilla.org/products/firefox">' +
      '<strong>Firefox Support</strong></a> instead of creating a bug.',
  },

  'Firefox for Android': {
    related: ['Core', 'Toolkit'],
    l10n: true,
    support:
      'If you are new to Firefox or Bugzilla, please consider checking ' +
      '<a href="https://support.mozilla.org/products/mobile">' +
      '<strong>Firefox for Android Support</strong></a> instead of creating a bug.',
  },

  Focus: {
    l10n: true,
  },

  SeaMonkey: {
    related: ['Core', 'Toolkit', 'MailNews Core'],
    l10n: true,
    version: () => {
      const re = /SeaMonkey\/(?<major>\d+)\.(?<minor>\d+)/i;
      const groups = navigator.userAgent.match(re)?.groups;
      if (groups) {
        const { major, minor } = groups;
        return `SeaMonkey ${major}.${minor} Branch`;
      }
      return false;
    },
  },

  Calendar: {
    l10n: true,
  },

  Thunderbird: {
    related: ['Core', 'Toolkit', 'MailNews Core'],
    l10n: true,
    defaultComponent: 'Untriaged',
    componentFilter: (components) => {
      const index = components.findIndex((c) => c.name === 'General');
      if (index !== -1) {
        components.splice(index, 1);
      }
      return components;
    },
    support:
      'If you are new to Thunderbird or Bugzilla, please consider checking ' +
      '<a href="https://support.mozilla.org/products/thunderbird">' +
      '<strong>Thunderbird Support</strong></a> instead of creating a bug.',
  },

  Bugzilla: {
    support:
      'Please use <a href="https://bugzilla-dev.allizom.org/">our test server</a> to file "test bugs".',
  },

  'bugzilla.mozilla.org': {
    related: ['Bugzilla'],
    support:
      'Please use <a href="https://bugzilla-dev.allizom.org/">our test server</a> to file "test bugs".',
  },
};
