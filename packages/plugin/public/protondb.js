// ProtonDB badge for Steam store and app pages.
//
// Steam's UI is a single-page app, so the badge is (re)mounted whenever the
// route changes rather than on load.

(() => {
	"use strict";

	const ENDPOINT = "https://www.protondb.com/api/v1/reports/summaries/";
	const BADGE_ID = "ember-protondb";

	const COLORS = {
		platinum: "#b4c7dc",
		gold: "#e5b94e",
		silver: "#a3a3a3",
		bronze: "#c77a3c",
		borked: "#e05b5b",
		pending: "#7a8a9e",
		native: "#33cc66",
	};

	const cache = new Map();

	const appId = () => {
		const match = location.pathname.match(/\/app\/(\d+)/);
		return match ? match[1] : null;
	};

	const mountPoint = () =>
		document.querySelector(".apphub_AppName") ||
		document.getElementById("appHubAppName") ||
		document.querySelector(".apphub_HeaderTop") ||
		document.querySelector(".apphub_HeaderStandardTop");

	async function summary(id) {
		if (cache.has(id)) {
			return cache.get(id);
		}
		const response = await fetch(ENDPOINT + id);
		if (!response.ok) {
			throw new Error(`ProtonDB ${response.status}`);
		}
		const data = await response.json();
		cache.set(id, data);
		return data;
	}

	function render(id, data) {
		const tier = String(data.tier || "pending").toLowerCase();

		const badge = document.createElement("a");
		badge.id = BADGE_ID;
		badge.href = `https://www.protondb.com/app/${id}`;
		badge.target = "_blank";
		badge.rel = "noreferrer";
		badge.textContent = `ProtonDB: ${tier}`;
		badge.title = data.total ? `${data.total} report(s)` : "ProtonDB";

		Object.assign(badge.style, {
			display: "inline-block",
			marginLeft: "10px",
			padding: "2px 8px",
			borderRadius: "3px",
			fontSize: "12px",
			fontWeight: "600",
			lineHeight: "18px",
			verticalAlign: "middle",
			textDecoration: "none",
			color: "#0e141b",
			background: COLORS[tier] || COLORS.pending,
		});

		const anchor = mountPoint();
		if (anchor) {
			anchor.appendChild(badge);
		}
	}

	async function run() {
		const id = appId();
		if (!id || document.getElementById(BADGE_ID)) {
			return;
		}

		try {
			render(id, await summary(id));
		} catch {
			// Unknown app, offline, or rate-limited: stay silent.
		}
	}

	document.getElementById(BADGE_ID)?.remove();

	let previous = "";
	setInterval(() => {
		if (location.pathname === previous) {
			return;
		}
		previous = location.pathname;
		// The header is rendered after the route settles.
		setTimeout(run, 900);
	}, 700);

	run();
})();
