/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * Extract the Socorro filters of a Crash Data URL.
 * Shared by the crash graph (socorro-lens) and the crash table so that both
 * apply the same filters.
 */
var CrashDataUrl = (function () {
  "use strict";

  var SEARCH_URL = "https://crash-stats.mozilla.org/search/?";

  // Signatures come from the bug, and each widget sets its own date range,
  // channels and versions. Parameters starting with "_" are display options.
  var IGNORED_PARAMS = ["signature", "date", "channel", "product", "version", "build_id"];

  // Return the filters as an array of encoded "key=value" strings.
  function getFilters(url) {
    var filters = [];
    if (!url || !url.startsWith(SEARCH_URL)) {
      return filters;
    }
    (new URL(url)).searchParams.forEach(function (value, key) {
      if (!key.startsWith("_") && !IGNORED_PARAMS.includes(key)) {
        filters.push(encodeURIComponent(key) + "=" + encodeURIComponent(value));
      }
    });
    return filters;
  }

  return {
    SEARCH_URL: SEARCH_URL,
    getFilters: getFilters,
  };
})();
