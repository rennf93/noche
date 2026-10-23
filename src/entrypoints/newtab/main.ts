import "../../ui/tokens.css";
import "./style.css";

// v1 glue only: a suggestion chip drops its prompt into the composer so the
// card feels alive. Chat wiring, camera and mic land with their own surfaces.
const field = document.querySelector<HTMLInputElement>(".field");
for (const chip of document.querySelectorAll<HTMLButtonElement>(".chip")) {
  chip.addEventListener("click", () => {
    if (field === null) return;
    field.value = chip.dataset.prompt ?? chip.textContent ?? "";
    field.focus();
  });
}
