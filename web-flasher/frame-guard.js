if (window.top !== window.self) {
  document.documentElement.replaceChildren();
  throw new Error("The firmware installer cannot run inside a frame.");
}
