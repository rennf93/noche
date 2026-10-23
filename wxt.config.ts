import { defineConfig } from "wxt";

export default defineConfig({
  srcDir: "src",
  manifest: {
    name: "Noche",
    description: "Local-first, AI-native assistance for any Chromium browser. BYO model.",
    permissions: ["storage", "tabs", "contextMenus", "sidePanel"],
    // The side panel surface is owned by the sidepanel entrypoint; declaring
    // the default path here lets the background open it programmatically.
    side_panel: { default_path: "sidepanel.html" },
  },
});
