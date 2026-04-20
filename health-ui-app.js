async function loadHealth() {
  const summary = document.getElementById("summary");
  const checks = document.getElementById("checks");
  const projects = document.getElementById("projects");

  try {
    const response = await fetch("/api/health", { cache: "no-store" });
    const payload = await response.json();
    const status = String(payload.summary || "unknown").toUpperCase();
    summary.textContent = `Status: ${status}`;
    summary.dataset.state = String(payload.summary || "unknown");

    checks.innerHTML = "";
    for (const check of payload.checks || []) {
      const card = document.createElement("article");
      card.className = "card";
      card.dataset.state = check.status || "unknown";
      card.innerHTML = `
        <div class="card-head">
          <h3>${check.name || "Check"}</h3>
          <span>${String(check.status || "unknown").toUpperCase()}</span>
        </div>
        <p>${check.detail || ""}</p>
      `;
      checks.appendChild(card);
    }

    const rows = payload.projects || [];
    if (!rows.length) {
      projects.textContent = "No projects discovered under ~/src yet.";
    } else {
      projects.innerHTML = rows.map((project) => `<div class="row"><strong>${project.name || "Project"}</strong><span>${project.path || ""}</span></div>`).join("");
    }
  } catch (error) {
    summary.textContent = `Health API failed: ${error}`;
    summary.dataset.state = "failed";
    checks.innerHTML = "";
    projects.textContent = "Unavailable";
  }
}

loadHealth();
setInterval(loadHealth, 5000);
