fetch('/status.json', { cache: 'no-store' })
  .then((response) => response.json())
  .then((status) => {
    document.getElementById('state').textContent = status.state;
    document.getElementById('message').textContent = status.message;
    const cost = status.costControl;
    if (cost) {
      document.getElementById('cost-model').textContent =
        `Cost control: ${cost.mode}. Planned estimate: USD ${cost.plannedEstimateUsd} ` +
        `against a USD ${cost.planningEstimateCeilingUsd} planning ceiling. ` +
        `Runtime exposure: at most ${cost.maximumRuntimeHours} hours. ` +
        `Actual billed cost: ${cost.actualBilledCost.status}.`;
    }
    if (status.state === 'OPEN' && status.applicationUrl) {
      location.assign(status.applicationUrl);
    }
  })
  .catch(() => {
    document.getElementById('state').textContent = 'STATUS UNAVAILABLE';
  });
