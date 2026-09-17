/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0.
 */

if (typeof MyDashboard === 'undefined') {
  var MyDashboard = {};
}

(() => {
  // Migrate legacy cookies set with YUI
  if (!Bugzilla.Storage.get('my_dashboard')) {
    const autoRefreshCookie = document.cookie.match(/\bmy_dashboard_autorefresh=(.+?)\b/);
    const queryCookie = document.cookie.match(/\bmy_dashboard_query=(.+?)\b/);

    Bugzilla.Storage.set('my_dashboard', {
      autoRefresh: autoRefreshCookie?.[1] === 'true',
      query: queryCookie?.[1] ?? '',
    });
  }
})();

// Main query code
window.addEventListener('DOMContentLoaded', () => {
  let lastChangesCache = {};
  let bugQueryTable = null;
  let default_query = 'assignedbugs';
  let refresh_interval = null;

  // Grab last used query name from storage or use default
  const { query, autoRefresh } = Bugzilla.Storage.get('my_dashboard', true);

  if (query) {
    const $option = document.querySelector(`#query option[value="${query}"]`);

    if ($option) {
      $option.selected = true;
      default_query = query;
    } else {
      Bugzilla.Storage.update('my_dashboard', { query: '' });
    }
  }

  // Grab last used auto-refresh configuration from storage or use default
  if (autoRefresh) {
    document.querySelector('#auto_refresh').checked = true;
  } else {
    Bugzilla.Storage.update('my_dashboard', { autoRefresh: false });
  }

  const updateQueryTable = async (query_name) => {
    if (!query_name) return;

    lastChangesCache = {};

    document.querySelector('#query_count_refresh').classList.add('bz_default_hidden');
    bugQueryTable.render([]);
    bugQueryTable.setMessage('LOADING');

    try {
      const { result } = await Bugzilla.API.get('mydashboard/run_bug_query', { query: query_name });
      const { buffer, bugs, description, heading, mark_read } = result;

      document.querySelector('#query_count_refresh').classList.remove('bz_default_hidden');
      document.querySelector('#query_container .query_description').innerHTML = description;
      document.querySelector('#query_container .query_heading').innerHTML = heading;
      document.querySelector('#query_bugs_found').innerHTML =
        `<a href="${BUGZILLA.config.basepath}buglist.cgi?${buffer}" ` +
        `target="_blank">${bugs.length} bugs found</a>`;
      bugQueryTable.render(bugs);

      if (mark_read) {
        document.querySelector('#query_markread').innerHTML = mark_read;
        document.querySelector('#bar_markread').classList.remove('bz_default_hidden');
        document.querySelector('#query_markread_text').innerHTML = mark_read;
        document.querySelector('#query_markread').classList.remove('bz_default_hidden');
      } else {
        document.querySelector('#bar_markread').classList.add('bz_default_hidden');
        document.querySelector('#query_markread').classList.add('bz_default_hidden');
      }

      document.querySelector('#query_markread_text').classList.add('bz_default_hidden');
    } catch {
      document.querySelector('#query_count_refresh').classList.remove('bz_default_hidden');
      bugQueryTable.setMessage(`Failed to load bug list.`);
    }
  };

  const updatedFormatter = ({ value, data: { changeddate_fancy } }) =>
    `<span title="${value.htmlEncode()}">${changeddate_fancy.htmlEncode()}</span>`;

  const link_formatter = ({ data, value }) =>
    `<a href="${BUGZILLA.config.basepath}show_bug.cgi?id=${data.bug_id}" target="_blank">
      ${isNaN(value) ? value.htmlEncode().wbr() : value}</a>`;

  /**
   * Show the last changes when the expander on a row is clicked.
   * @param {object} row Row data.
   */
  const expandRow = async ({ data, $extraContent }) => {
    bugQueryTable.setMessage('');

    const { bug_id, changeddate_api } = data;
    const $target = $extraContent;

    $target.textContent = 'Loading...';

    if (!lastChangesCache[bug_id]) {
      try {
        const {
          results: [{ last_changes: lastChanges }],
        } = await Bugzilla.API.get('mydashboard/run_last_changes', { bug_id, changeddate_api });

        lastChangesCache[bug_id] = lastChanges;
      } catch {
        $target.textContent = 'Failed to load last changes.';
      }
    }

    if (lastChangesCache[bug_id]) {
      const { email, when, activity, comment_html = '' } = lastChangesCache[bug_id];

      $target.innerHTML = `
        <div id="last_changes_${bug_id}">
          ${
            email
              ? `
                <div id="last_changes_header">
                  Last Changes :: ${email.htmlEncode()} :: ${when.htmlEncode()}
                </div>
                ${
                  activity
                    ? `
                      <table id="activity">
                      ${activity
                        .map(
                          ({ field_desc, added, removed }) => `
                            <tr>
                              <td class="field_label">${field_desc.htmlEncode()}:</td>
                              <td class="field_data">
                              ${
                                removed && !added
                                  ? `Removed: ${removed.htmlEncode()}`
                                  : !removed && added
                                  ? `Added: ${added.htmlEncode()}`
                                  : `${removed.htmlEncode()} &rarr; ${added.htmlEncode()}`
                              }
                              </td>
                            </tr>
                          `,
                        )
                        .join('')}
                      </table>
                    `
                    : ``
                }
                ${comment_html}
              `
              : `This is a new ${BUGZILLA.string.bug} and no changes have been made yet.`
          }
        </div>
      `;
    }
  };

  bugQueryTable = new Bugzilla.DataTable({
    container: '#query_table',
    columns: [
      { key: '_expander', label: ' ', sortable: false },
      {
        key: 'bug_type',
        label: 'T',
        allowHTML: true,
        formatter:
          '<span class="bug-type-label iconic" title="{value}" aria-label="{value}" ' +
          'data-type="{value}"><span class="icon" aria-hidden="true"></span></span>',
      },
      { key: 'bug_id', label: 'Bug', allowHTML: true, formatter: link_formatter },
      { key: 'changeddate', label: 'Updated', formatter: updatedFormatter, allowHTML: true },
      { key: 'priority', label: 'Pri', allowHTML: true },
      { key: 'bug_status', label: 'Status' },
      { key: 'short_desc', label: 'Summary', allowHTML: true, formatter: link_formatter },
    ],
    strings: {
      EMPTY: 'Zarro Boogs found',
    },
    options: {
      expandRow,
    },
  });

  const auto_updateQueryTable = () => {
    if (document.querySelector('#auto_refresh').checked) {
      refresh_interval = setInterval(() => {
        updateQueryTable(default_query);
      }, 1000 * 60 * 10);
    } else {
      clearInterval(refresh_interval);
    }
  };

  // Initial load — fall back to reportedbugs if assignedbugs is empty
  // and no saved preference exists (helps new users with no assigned bugs).
  updateQueryTable(default_query).then(() => {
    if (default_query === 'assignedbugs' && !query && bugQueryTable.data.length === 0) {
      const $option = document.querySelector('#query option[value="reportedbugs"]');
      if ($option) {
        $option.selected = true;
        default_query = 'reportedbugs';
        updateQueryTable('reportedbugs');
      }
    }
  });
  auto_updateQueryTable();

  document.querySelector('#query').addEventListener('change', (e) => {
    const selected_value = e.target.value;

    updateQueryTable(selected_value);
    Bugzilla.Storage.update('my_dashboard', { query: selected_value });
  });

  document.querySelector('#query_refresh').addEventListener('click', () => {
    const query_select = document.querySelector('#query');
    const selected_value = query_select.value;

    updateQueryTable(selected_value);
  });

  document.querySelector('#auto_refresh').addEventListener('click', (e) => {
    auto_updateQueryTable();
    Bugzilla.Storage.update('my_dashboard', { autoRefresh: e.target.checked });
  });

  document.querySelector('#query_markread').addEventListener('click', () => {
    const ids = bugQueryTable.data.map(({ data }) => data.bug_id);

    document.querySelector('#query_markread').classList.add('bz_default_hidden');
    document.querySelector('#query_markread_text').classList.remove('bz_default_hidden');

    Bugzilla.API.post('bug_user_last_visit', { ids });
    Bugzilla.API.put('mydashboard/bug_interest_unmark', { bug_ids: ids });
  });

  document.querySelector('#query_buglist').addEventListener('click', () => {
    const ids = bugQueryTable.data.map(({ data }) => data.bug_id);
    const url = `${BUGZILLA.config.basepath}buglist.cgi?bug_id=${ids.join('%2C')}`;

    window.open(url, '_blank');
  });
});
