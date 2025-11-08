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

  ctx.handleEvent("focus_editor", () => {
    // Focus the editor after clearing
    setTimeout(() => {
      const editor = document.querySelector(
        ".cell--code.cell--evaluating + .cell--code textarea, .cell--code textarea",
      );
      if (editor) {
        editor.focus();
      }
    }, 100);
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
        <h3 class="header-title">Prompt Buddy</h3>
        <select class="form-select" aria-label="Select model">
          ${options}
        </select>
          <span class="hint">${SHORTCUT_HINT}</span>
      </div>
    </div>
  `;
}
