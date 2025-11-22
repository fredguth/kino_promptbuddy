const MODEL_OPTIONS = [
  { value: "sonnet", label: "Sonnet" },
  { value: "haiku", label: "Haiku" },
  { value: "opus", label: "Opus" },
];

const DEFAULT_MODEL = "sonnet";
const isMac =
  typeof navigator !== "undefined" &&
  /Mac|iPhone|iPad/.test(navigator.platform ?? "");
const SHORTCUT_HINT = isMac ? "⌘↩" : "Ctrl↩";

export function init(ctx, payload) {
  ctx.importCSS("main.css");

  const activeTab = payload?.active_tab || "prompt";

  ctx.root.innerHTML = renderForm(activeTab);
  ctx.pushEvent("set_session_id", document.baseURI);

  setupModelSelect(ctx, payload);
  setupTabs(ctx, activeTab);

  // Set initial mode indicator on form
  const form = ctx.root.querySelector(".buddy-form");
  if (form) {
    form.setAttribute("data-active-mode", activeTab);
  }
}

function setupTabs(ctx, initialTab = "prompt") {
  const tabs = ctx.root.querySelectorAll(".tab");

  // Set initial active tab
  tabs.forEach((tab) => {
    if (tab.dataset.tab === initialTab) {
      tab.classList.add("active");
    } else {
      tab.classList.remove("active");
    }
  });

  tabs.forEach((tab) => {
    tab.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();

      const tabName = tab.dataset.tab;

      // Update tab active states
      tabs.forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");

      // Update form mode indicator
      const form = ctx.root.querySelector(".buddy-form");
      if (form) {
        form.setAttribute("data-active-mode", tabName);
      }

      ctx.pushEvent("tab_changed", { tab: tabName });
    });
  });
}

function setupModelSelect(ctx, payload) {
  const modelSelect = ctx.root.querySelector(".form-select");
  if (!modelSelect) return;

  modelSelect.value = modelKeyFromPayload(payload);
  modelSelect.addEventListener("change", (event) => {
    ctx.pushEvent("update_model", event.target.value);
  });
}

function modelKeyFromPayload(payload) {
  const model = payload?.model;
  if (!model) return DEFAULT_MODEL;

  const matched = MODEL_OPTIONS.find(({ value }) => model.includes(value));
  return matched?.value ?? DEFAULT_MODEL;
}

function renderForm(activeTab = "prompt") {
  const options = MODEL_OPTIONS.map(
    ({ value, label }) =>
      `<option value="${value}"${
        value === DEFAULT_MODEL ? " selected" : ""
      }>${label}</option>`,
  ).join("");

  return `
    <div class="buddy-form">
      <div class="form-header">
        <div class="tabs">
          <button type="button" class="tab ${activeTab === "prompt" ? "active" : ""}" data-tab="prompt">Prompt</button>
          <button type="button" class="tab ${activeTab === "note" ? "active" : ""}" data-tab="note">Note</button>
          <button type="button" class="tab ${activeTab === "code" ? "active" : ""}" data-tab="code">Code</button>
        </div>
        <div class="controls">
          <select class="form-select" aria-label="Select model">
            ${options}
          </select>
          <span class="hint">${SHORTCUT_HINT}</span>
        </div>
      </div>
    </div>
  `;
}
