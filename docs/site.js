// Every number on the site comes from benchmarks.json, which `rake bench` rewrites before each release.
const METRICS = [
  { key: "median_milliseconds", title: "Time to render", better: "lower", format: (value) => formatSeconds(value) },
  { key: "allocations", title: "Objects allocated per render", better: "lower" },
  { key: "bytes", title: "File weight", better: "lower", format: (value) => formatBytes(value) },
  { key: "peak_memory_megabytes", title: "Peak memory of the process", better: "lower", format: (value) => `${formatNumber(value)} MB` }
];
const ENGINE_NAMES = { prawn: "Prawn", prawnx: "PrawnX" };
const DOCUMENT_DESCRIPTIONS = {
  invoice: "A one-page invoice: an embedded TrueType font, a JPEG letterhead, a ten-line table.",
  report: "A 50-page report: an embedded TrueType font, a PNG with alpha and a JPEG on every page, justified text.",
  catalog: "A long catalog: a thousand table rows over many pages, the header repeated on each one."
};

const element = (tag, attributes = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (name === "style") Object.entries(value).forEach(([property, setting]) => node.style.setProperty(property, setting));
    else node.setAttribute(name, value);
  }
  node.append(...children);
  return node;
};
const formatNumber = (value) => value.toLocaleString("en");
const formatRatio = (ratio) => `${Number(ratio.toFixed(ratio < 10 ? 1 : 0))}×`;
const formatSeconds = (milliseconds) => milliseconds < 1000 ? `${formatNumber(milliseconds)} ms` : `${(milliseconds / 1000).toFixed(1)} s`;
const formatBytes = (bytes) => `${formatNumber(Math.round(bytes / 1000))} kB`;
const formatPercent = (ratio) => `${Math.round(ratio * 100)}%`;
const fill = (selector, text) => document.querySelectorAll(selector).forEach((node) => { node.textContent = text; });
const capitalized = (name) => name.charAt(0).toUpperCase() + name.slice(1);

function columnChart({ title, better, rows, format = formatNumber, heading = "h3" }) {
  const maximum = Math.max(...rows.map((row) => row.value));
  const columns = element("div", { class: "columns", style: { "--count": rows.length }, role: "img", "aria-label": `${title}: ${rows.map((row) => `${row.name} ${format(row.value)}`).join(", ")}` });
  for (const row of rows) {
    const ours = row.name.startsWith("PrawnX") ? " ours" : "";
    columns.append(element("div", { class: `column${ours}`, title: `${row.label || row.name}: ${format(row.value)}` },
      element("span", { class: "column-value" }, format(row.value)),
      element("div", { class: `column-bar${ours}`, style: { height: `${(row.value / maximum) * 100}%` } }),
      element("span", { class: "column-name" }, row.name)));
  }
  const table = element("table", {},
    element("thead", {}, element("tr", {}, element("th", { scope: "col" }, "Engine"), element("th", { scope: "col", class: "number" }, title))),
    element("tbody", {}, ...rows.map((row) => element("tr", {},
      element("th", { scope: "row" }, row.label || row.name),
      element("td", { class: "number" }, format(row.value))))));
  return element("figure", { class: "chart" },
    element(heading, {}, `${title} `, element("small", {}, `(${better} is better)`)),
    columns,
    element("details", {}, element("summary", {}, "Table"), table));
}

// Each document's Prawn measure divided by PrawnX's: how many times faster, fewer, lighter.
function ratiosBy(benchmarks, key) {
  return Object.entries(benchmarks.results).map(([name, measures]) => ({ name, ratio: measures.prawn[key] / measures.prawnx[key], prawn: measures.prawn[key], prawnx: measures.prawnx[key] }));
}

// The smallest ratio of all documents: the headline never picks the flattering one.
const weakest = (ratios) => ratios.reduce((weakest, entry) => entry.ratio < weakest.ratio ? entry : weakest);
const strongest = (ratios) => ratios.reduce((strongest, entry) => entry.ratio > strongest.ratio ? entry : strongest);

function measuredOn(benchmarks) {
  const ruby = benchmarks.ruby.split(" (")[0].replace("ruby", "Ruby");
  return `Measured on ${ruby} with YJIT, each engine in its own process, median of ${benchmarks.iterations} renders.`;
}

function renderHome(benchmarks) {
  const tiles = document.getElementById("tiles");
  if (!tiles) return;
  const speed = ratiosBy(benchmarks, "median_milliseconds");
  const allocations = ratiosBy(benchmarks, "allocations");
  const weight = ratiosBy(benchmarks, "bytes");
  const memory = ratiosBy(benchmarks, "peak_memory_megabytes");
  fill("#byline-speed", `Prawn’s API, ${formatRatio(weakest(speed).ratio)} faster or more.`);

  const tile = (value, label, detail) => element("div", { class: "tile" },
    element("span", { class: "tile-value" }, value), element("span", { class: "tile-label" }, label), element("span", { class: "tile-detail" }, detail));
  const fastest = strongest(speed);
  tiles.append(
    tile(formatRatio(weakest(speed).ratio), "faster, at the least", `The ${fastest.name}: ${formatSeconds(fastest.prawnx)} instead of ${formatSeconds(fastest.prawn)}, ${formatRatio(fastest.ratio)} faster`),
    tile(formatRatio(weakest(allocations).ratio), "fewer allocations, at the least", `The ${strongest(allocations).name}: ${formatNumber(strongest(allocations).prawnx)} objects instead of ${formatNumber(strongest(allocations).prawn)}`),
    tile(formatPercent(1 - 1 / weakest(weight).ratio), "lighter files, at the least", `The ${strongest(weight).name}: ${formatBytes(strongest(weight).prawnx)} instead of ${formatBytes(strongest(weight).prawn)}, the same pixels`),
    tile(formatPercent(1 - 1 / weakest(memory).ratio), "less peak memory, at the least", `The ${strongest(memory).name}: ${formatNumber(strongest(memory).prawnx)} MB instead of ${formatNumber(strongest(memory).prawn)} MB`));
  fill("#tiles-note", `${measuredOn(benchmarks)} Each headline is the weakest of the three documents on the benchmarks page.`);
}

function renderBenchmarks(benchmarks) {
  fill("#bench-note", `Each document rendered by Prawn 2.5 with prawn-table, and by PrawnX. ${measuredOn(benchmarks)}`);
  const documents = document.getElementById("documents");
  for (const [name, measures] of Object.entries(benchmarks.results)) {
    const rowsFor = (key) => Object.entries(measures).map(([engine, engineMeasures]) => ({ name: ENGINE_NAMES[engine] || engine, value: engineMeasures[key] }));
    documents.append(element("div", { class: "corpus" },
      element("h3", {}, capitalized(name)),
      element("p", { class: "note" }, DOCUMENT_DESCRIPTIONS[name] || ""),
      element("div", { class: "charts" }, ...METRICS.map((metric) => columnChart({ ...metric, heading: "h4", rows: rowsFor(metric.key) })))));
  }
}

fetch("benchmarks.json").then((response) => response.json()).then((benchmarks) => {
  renderHome(benchmarks);
  if (document.getElementById("documents")) renderBenchmarks(benchmarks);
}).catch(() => {
  fill("#bench-note, #tiles-note", "The benchmark numbers could not be loaded: see docs/benchmarks.json in the repository.");
});
