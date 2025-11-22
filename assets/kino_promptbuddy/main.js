// Version: 2.0 - Force cache invalidation
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

console.log("PromptBuddy JS loaded - Version 2.0");

// Set up storage listener in parent window if we're in an iframe
if (window.parent && window.parent !== window) {
  // Inject style controller into parent window using localStorage events
  const parentScript = `
    (function() {
      if (window.promptBuddyListenerInstalled) return;
      window.promptBuddyListenerInstalled = true;
      console.log('PromptBuddy parent listener installed');

      // Poll localStorage since storage events don't fire in same window
      // Check every 100ms for changes
      let lastMode = localStorage.getItem('promptbuddy_mode') || '';

      setInterval(function() {
        const currentMode = localStorage.getItem('promptbuddy_mode') || '';
        if (currentMode !== lastMode) {
          lastMode = currentMode;
          console.log('PromptBuddy mode changed to:', currentMode);

          // Find all editor containers and update their class
          document.querySelectorAll('[data-el-editor-container]').forEach(function(container) {
            container.classList.remove('promptbuddy-mode-prompt', 'promptbuddy-mode-note', 'promptbuddy-mode-code');
            if (currentMode) {
              container.classList.add('promptbuddy-mode-' + currentMode);
              console.log('Added class to container:', 'promptbuddy-mode-' + currentMode);
            }
          });
        }
      }, 100);

      // Also apply initial value immediately
      if (lastMode) {
        document.querySelectorAll('[data-el-editor-container]').forEach(function(container) {
          container.classList.add('promptbuddy-mode-' + lastMode);
          console.log('Initial class added:', 'promptbuddy-mode-' + lastMode);
        });
      }
    })();
  `;

  // Try to execute in parent context
  try {
    window.parent.eval(parentScript);
  } catch (e) {
    console.log("Could not inject into parent (cross-origin):", e);
  }
}

export function init(ctx, payload) {
  ctx.importCSS("main.css");

  const activeTab = payload?.active_tab || "prompt";

  // Set initial data-active-tab attribute on cell container
  const cellContainer = ctx.root.closest(".cell");
  if (cellContainer) {
    cellContainer.setAttribute("data-active-tab", activeTab);
  }

  ctx.root.innerHTML = renderForm(activeTab);
  ctx.pushEvent("set_session_id", document.baseURI);

  setupModelSelect(ctx, payload);
  setupTabs(ctx, activeTab);

  // Set initial mode indicator
  setTimeout(() => {
    const form = ctx.root.querySelector(".buddy-form");
    if (form) {
      form.setAttribute("data-active-mode", activeTab);
      console.log("Set initial data-active-mode:", activeTab);
    }
  }, 10);

  // Apply initial editor styles after a brief delay to ensure editor is mounted
  setTimeout(() => {
    applyEditorStyles(cellContainer, activeTab);
  }, 100);

  // Watch for editor changes and reapply styles
  if (cellContainer) {
    const observer = new MutationObserver(() => {
      const currentTab =
        cellContainer.getAttribute("data-active-tab") || "prompt";
      applyEditorStyles(cellContainer, currentTab);
    });

    observer.observe(cellContainer, {
      childList: true,
      subtree: true,
    });
  }

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

function setupTabs(ctx, initialTab = "prompt") {
  const tabs = ctx.root.querySelectorAll(".tab");
  console.log(`setupTabs: found ${tabs.length} tabs, initialTab=${initialTab}`);

  // Set initial active tab
  tabs.forEach((tab) => {
    if (tab.dataset.tab === initialTab) {
      tab.classList.add("active");
    } else {
      tab.classList.remove("active");
    }
  });

  tabs.forEach((tab) => {
    console.log(`Adding click listener to tab: ${tab.dataset.tab}`);
    tab.addEventListener("click", (e) => {
      console.log(`Tab clicked: ${tab.dataset.tab}`);

      // Remove active from all tabs
      tabs.forEach((t) => t.classList.remove("active"));

      // Add active to clicked tab
      tab.classList.add("active");

      // Get tab name and send to backend
      const tabName = tab.dataset.tab;

      // Find the cell container - try multiple approaches
      let cellContainer = ctx.root.closest(".cell");
      if (!cellContainer) {
        // Try finding by going up through parents
        let parent = ctx.root.parentElement;
        let attempts = 0;
        while (parent && !parent.classList.contains("cell") && attempts < 10) {
          parent = parent.parentElement;
          attempts++;
        }
        cellContainer = parent;
      }

      console.log("cellContainer:", cellContainer);
      console.log("ctx.root:", ctx.root);
      console.log("ctx.root.parentElement:", ctx.root.parentElement);

      if (cellContainer) {
        cellContainer.setAttribute("data-active-tab", tabName);
        console.log("Set data-active-tab to:", tabName, "on cell");
      }

      // Also set on the root element itself
      ctx.root.setAttribute("data-active-tab", tabName);

      // Set data-active-mode on the form to show visual indicator
      const form = ctx.root.querySelector(".buddy-form");
      if (form) {
        form.setAttribute("data-active-mode", tabName);
        console.log("Set data-active-mode on form:", tabName);
      }

      // Use localStorage to communicate with parent page
      // This works across iframes on the same origin
      try {
        localStorage.setItem("promptbuddy_mode", tabName);
        localStorage.setItem("promptbuddy_timestamp", Date.now().toString());
        console.log("Set localStorage promptbuddy_mode:", tabName);
      } catch (e) {
        console.log("Could not set localStorage:", e);
      }

      ctx.pushEvent("tab_changed", { tab: tabName });
    });
  });
}

function applyEditorStyles(cellContainer, tabName) {
  if (!cellContainer) {
    console.log("applyEditorStyles: no cellContainer");
    return;
  }

  const editorElements = cellContainer.querySelectorAll(
    ".cm-editor, .cm-scroller, .cm-content, .cm-gutters, .cm-line, .cm-activeLineGutter",
  );

  console.log(
    `applyEditorStyles: tabName=${tabName}, found ${editorElements.length} elements`,
  );

  const styles = {
    prompt: { bg: "#ffffff", color: "#1f2937" },
    note: { bg: "#eeeee1", color: "#374151" },
    code: { bg: "#1e1e1e", color: "#d4d4d4" },
  };

  const style = styles[tabName] || styles.prompt;

  editorElements.forEach((el) => {
    el.style.backgroundColor = style.bg;
    el.style.color = style.color;
  });

  console.log(`Applied styles: bg=${style.bg}, color=${style.color}`);

  // Also update cursor color for code tab
  if (tabName === "code") {
    const cursors = cellContainer.querySelectorAll(".cm-cursor");
    cursors.forEach((cursor) => {
      cursor.style.borderLeftColor = "#d4d4d4";
    });
  }
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
          <button class="tab ${activeTab === "prompt" ? "active" : ""}" data-tab="prompt">Prompt</button>
          <button class="tab ${activeTab === "note" ? "active" : ""}" data-tab="note">Note</button>
          <button class="tab ${activeTab === "code" ? "active" : ""}" data-tab="code">Code</button>
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
