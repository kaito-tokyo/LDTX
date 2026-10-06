// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

// Keep the embedded source readable if the CDN cannot be reached.
class GherkinScenario extends HTMLElement {
  async connectedCallback() {
    const source = this.querySelector("pre");
    if (!source) return;
    try {
      const { Parser, AstBuilder, GherkinClassicTokenMatcher } = await import(
        "https://esm.sh/@cucumber/gherkin@42.0.1?bundle&target=es2022"
      );
      let nextID = 0;
      const parser = new Parser(
        new AstBuilder(() => String(++nextID)),
        new GherkinClassicTokenMatcher(),
      );
      const gherkinDocument = parser.parse(source.textContent);
      if (!gherkinDocument.feature) throw new Error("The document has no Feature.");
      const article = element("article");
      renderBlock(gherkinDocument.feature, article, 2);
      if (source.parentElement === this) {
        this.replaceChildren(article);
        const anchor = article.querySelectorAll("[id]");
        for (const target of anchor) {
          if (`#${target.id}` === window.location.hash) target.scrollIntoView();
        }
      }
    } catch (error) {
      console.warn("Unable to render Gherkin; retaining the original source.", error);
    }
  }
}

function element(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderTable(rows, parent) {
  const table = element("table");
  for (const row of rows) {
    const tr = element("tr");
    for (const cell of row.cells) tr.append(element("td", cell.value));
    table.append(tr);
  }
  parent.append(table);
}

function renderBlock(block, parent, level) {
  const caseTag = block.tags?.find((tag) => /^@UCT-\d+(?:\.\d+)?$/.test(tag.name));
  if (caseTag) parent.id = caseTag.name.slice(1);
  if (block.tags?.length) {
    const tags = element("p");
    for (const tag of block.tags) {
      if (tags.childNodes.length) tags.append(document.createTextNode(" "));
      if (tag === caseTag) {
        const link = element("a", tag.name);
        link.setAttribute("href", `#${parent.id}`);
        tags.append(link);
      } else {
        tags.append(document.createTextNode(tag.name));
      }
    }
    parent.append(tags);
  }
  parent.append(element(`h${Math.min(level, 6)}`, `${block.keyword}: ${block.name}`));
  if (block.description) parent.append(element("p", block.description));
  if (block.steps?.length) {
    const steps = element("ol");
    for (const step of block.steps) {
      const item = element("li");
      item.append(element("strong", step.keyword), document.createTextNode(step.text));
      if (step.docString) item.append(element("pre", step.docString.content));
      if (step.dataTable) renderTable(step.dataTable.rows, item);
      steps.append(item);
    }
    parent.append(steps);
  }
  for (const example of block.examples ?? []) {
    const section = element("section");
    renderBlock(example, section, level + 1);
    renderTable([example.tableHeader, ...example.tableBody].filter(Boolean), section);
    parent.append(section);
  }
  for (const child of block.children ?? []) {
    const nested = child.scenario ?? child.background ?? child.rule;
    if (!nested) continue;
    const section = element("section");
    renderBlock(nested, section, level + 1);
    parent.append(section);
  }
}

customElements.define("gherkin-scenario", GherkinScenario);
