const status = document.querySelector(".status-pill");
const statusText = document.querySelector("#api-status");
const serviceName = document.querySelector("#service-name");
const serviceVersion = document.querySelector("#service-version");
const serviceEnvironment = document.querySelector("#service-environment");

async function loadServiceInfo() {
  try {
    const [healthResponse, infoResponse] = await Promise.all([
      fetch("/api/health", { headers: { Accept: "application/json" } }),
      fetch("/api/info", { headers: { Accept: "application/json" } }),
    ]);

    if (!healthResponse.ok || !infoResponse.ok) {
      throw new Error("Service request failed");
    }

    const [health, info] = await Promise.all([
      healthResponse.json(),
      infoResponse.json(),
    ]);

    status.dataset.status = health.status === "ok" ? "ok" : "error";
    statusText.textContent = health.status === "ok" ? "API operational" : "API unavailable";
    serviceName.textContent = info.service;
    serviceVersion.textContent = info.version;
    serviceEnvironment.textContent = info.environment;
  } catch {
    status.dataset.status = "error";
    statusText.textContent = "API unavailable";
    serviceName.textContent = "Unavailable";
    serviceVersion.textContent = "Unavailable";
    serviceEnvironment.textContent = "Unavailable";
  }
}

loadServiceInfo();
