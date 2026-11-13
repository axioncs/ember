// Renders the ProtonDB pill on a Steam store app page.
//
// Evaluated over CDP by `ember ui attach`. The tier arrives as a JSON literal
// from the host, because the store page's CSP refuses the fetch: that request is
// made by the CLI with curl, not by this page. Idempotent — re-running it
// updates the pill instead of adding a second one.
(function () {
	var APPID = __EMBER_APPID__;
	var TIER = __EMBER_TIER_JSON__;
	var KEY = "__ember_protondb";

	if (!/^\/app\/\d+/.test(location.pathname)) return "skip: not an app page";
	if (String(location.pathname).indexOf("/app/" + APPID) !== 0) return "skip: page moved";

	var COLORS = {
		platinum: "#b4c7dc",
		gold: "#e5c15a",
		silver: "#b9c2c9",
		bronze: "#cd7f32",
		borked: "#e04b4b",
		pending: "#8a8a8a"
	};
	var LABELS = {
		platinum: "Platinum",
		gold: "Gold",
		silver: "Silver",
		bronze: "Bronze",
		borked: "Borked",
		pending: "Pending"
	};

	var tier = (TIER && TIER.tier) || "pending";
	var colour = COLORS[tier] || COLORS.pending;

	var pill = document.getElementById(KEY);
	if (!pill) {
		// Steam's store header keeps links to the hub and friends in this row;
		// fall back to the title block, then to a fixed badge, so a markup change
		// degrades to something visible instead of nothing.
		var anchor =
			document.querySelector(".apphub_OtherSiteInfo") ||
			document.querySelector(".apphub_AppName") ||
			document.querySelector(".apphub_HeaderTop");

		pill = document.createElement("a");
		pill.id = KEY;
		pill.target = "_blank";
		pill.rel = "noopener noreferrer";
		pill.style.cssText = [
			"display:inline-flex",
			"align-items:center",
			"gap:6px",
			"margin:0 0 0 6px",
			"padding:4px 10px",
			"border-radius:3px",
			"background:rgba(0,0,0,0.35)",
			"font:12px/1.4 'Motiva Sans',Arial,sans-serif",
			"text-decoration:none",
			"vertical-align:middle"
		].join(";");

		var dot = document.createElement("span");
		dot.style.cssText =
			"width:9px;height:9px;border-radius:50%;display:inline-block;flex:0 0 auto";
		dot.setAttribute("data-ember-dot", "");

		var label = document.createElement("span");
		label.setAttribute("data-ember-label", "");
		label.style.cssText = "color:#c6d4df";

		pill.appendChild(dot);
		pill.appendChild(label);

		if (anchor) {
			anchor.appendChild(pill);
		} else {
			pill.style.position = "fixed";
			pill.style.right = "16px";
			pill.style.bottom = "16px";
			pill.style.zIndex = "2147483000";
			document.body.appendChild(pill);
		}
	}

	pill.href = "https://www.protondb.com/app/" + APPID;
	pill.title = "ProtonDB: " + (LABELS[tier] || tier) +
		(TIER && typeof TIER.total === "number" && TIER.total > 0
			? " (" + TIER.total + " reports)"
			: "");
	pill.querySelector("[data-ember-dot]").style.background = colour;
	pill.querySelector("[data-ember-label]").textContent =
		"ProtonDB: " + (LABELS[tier] || tier);

	return "ok: " + tier;
})();
