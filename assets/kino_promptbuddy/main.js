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
  ctx.root.innerHTML = renderForm();
  ctx.pushEvent("set_session_id", document.baseURI);

  setupModelSelect(ctx, payload);
  setupRunButton(ctx, payload);

  ctx.handleEvent("clear_editor", ({ cell_id }) => {
    console.log(
      "[PromptBuddy] clear_editor event ignored inside JS iframe for cell",
      cell_id,
    );
  });

  ctx.handleEvent("focus_editor", ({ cell_id }) => {
    console.log(
      "[PromptBuddy] focus_editor event ignored inside JS iframe for cell",
      cell_id,
    );
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

function setupRunButton(ctx, payload = {}) {
  const runButton = ctx.root.querySelector(".form-run");
  if (!runButton) return;

  runButton.addEventListener("click", () => {
    ctx.pushEvent("evaluate_cell", {
      cell_id: payload.cell_id,
      session_id: payload.session_id,
    });
  });
}

function modelKeyFromPayload(payload) {
  const model = payload?.model;
  if (!model) return DEFAULT_MODEL;

  const matched = MODEL_OPTIONS.find(({ value }) => model.includes(value));
  return matched?.value ?? DEFAULT_MODEL;
}

function renderForm() {
  const options = MODEL_OPTIONS.map(
    ({ value, label }) =>
      `<option value="${value}"${
        value === DEFAULT_MODEL ? " selected" : ""
      }>${label}</option>`,
  ).join("");

  return `
    <div class="buddy-form">
      <div class="form-header">
        <h3 class="header-title">Prompt</h3>
        <select class="form-select" aria-label="Select model">
          ${options}
        </select>
        <button type="button" class="form-run" aria-label="Send (${SHORTCUT_HINT})">
          <span>Send</span>
          <span class="hint">${SHORTCUT_HINT}</span>
        </button>
      </div>
    </div>
  `;
}
