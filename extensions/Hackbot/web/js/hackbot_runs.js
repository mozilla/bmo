/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

"use strict";

const HackbotRuns = {
  STATUS_LABELS: {
    pending:   { label: "pending",   cls: "hb-status-pending"   },
    running:   { label: "running",   cls: "hb-status-running"   },
    succeeded: { label: "succeeded", cls: "hb-status-succeeded" },
    failed:    { label: "failed",    cls: "hb-status-failed"    },
    timed_out: { label: "timed out", cls: "hb-status-failed"    },
    unknown:   { label: "unknown",   cls: "hb-status-pending"   },
  },

  ORIGIN_LABELS: {
    needinfo: "needinfo",
    ui:       "Hackbot UI",
    other:    "Hackbot",
  },

  cell(className, content) {
    const td = document.createElement("td");
    td.className = className;
    if (content instanceof Node) {
      td.appendChild(content);
    } else {
      td.textContent = content ?? "—";
    }
    return td;
  },

  statusBadge(status) {
    const info = this.STATUS_LABELS[status] || this.STATUS_LABELS.unknown;
    const badge = document.createElement("span");
    badge.className = `hb-status-badge ${info.cls}`;
    badge.textContent = info.label;
    return badge;
  },

  originText(run) {
    const label = this.ORIGIN_LABELS[run.origin] || this.ORIGIN_LABELS.other;
    return run.requester ? `${label} by :${run.requester}` : label;
  },

  // A relative time ("4 minutes ago") that bug_modal.js keeps up to date via
  // the rel-time class, with the absolute time as a tooltip.
  startedAt(createdAt) {
    const date = createdAt ? new Date(createdAt) : null;
    if (!date || isNaN(date)) return null;
    const span = document.createElement("span");
    span.className = "rel-time";
    span.dataset.time = Math.floor(date.getTime() / 1000);
    span.title = date.toLocaleString();
    span.textContent = timeAgo(date);
    return span;
  },

  viewLink(url) {
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = "view run";
    return link;
  },

  buildRow(run) {
    const tr = document.createElement("tr");
    tr.appendChild(this.cell("hb-col-agent", run.agent));
    tr.appendChild(this.cell("hb-col-status", this.statusBadge(run.status)));
    tr.appendChild(this.cell("hb-col-origin", this.originText(run)));
    tr.appendChild(this.cell("hb-col-started", this.startedAt(run.created_at)));
    tr.appendChild(this.cell("hb-col-link", this.viewLink(run.url)));
    return tr;
  },

  async onLoad() {
    const module = document.getElementById("hackbot-runs-module");
    const tbody = module?.querySelector("tbody.hackbot-runs-body");
    if (!tbody) return;

    try {
      const { runs } = await Bugzilla.API.get(
        `hackbot/bug_runs/${BUGZILLA.bug_id}`
      );

      // Like the other integrations, the module only appears when there is
      // something to show. A Hackbot outage keeps it hidden as well, rather
      // than putting an error box on every bug page (it's logged server-side).
      if (!runs || runs.length === 0) return;

      for (const run of runs) {
        tbody.appendChild(this.buildRow(run));
      }
      module.querySelector(".hackbot-run-count")?.replaceChildren(
        `${runs.length} run${runs.length === 1 ? "" : "s"} for this bug`
      );
      module.classList.remove("bz_default_hidden");
    } catch (e) {
      console.error("Error loading Hackbot runs:", e);
    }
  },
};

window.addEventListener("DOMContentLoaded", () => {
  HackbotRuns.onLoad();
});
