import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { initTheme } from "./components/layout/ThemeToggle";
import "./styles/global.css";

initTheme();

const root = document.getElementById("root");
if (root === null) {
  throw new Error("#root missing");
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
