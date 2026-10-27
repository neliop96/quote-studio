      let projectDraftLines = [];

      function renderProjects() {
        const categories = [...new Set(products.map((product) => product.category).filter(Boolean))];
        options(
          "projectCategory",
          categories.map((category) => ({ value: category, label: category })),
        );
        renderProjectSubcategories();
        renderProjectDraft();
        $("projectsRows").innerHTML =
          projects
            .map((project) => {
              const items = Array.isArray(project.items) ? project.items : [];
              const productList = items
                .map((item) => {
                  const product = products.find((entry) => entry.id === item.product_id);
                  const label = product
                    ? `${product.part} — ${product.description}`
                    : "Unavailable product";
                  return `<li>${esc(label)} × ${esc(item.qty)}</li>`;
                })
                .join("");
              const canDelete =
                project.created_by === user?.id || isAdminRole();
              return `<tr><td>${esc(project.name)}</td><td><details><summary>${items.length} products</summary><ul class="project-items">${productList}</ul></details></td><td>${esc(new Date(project.created_at).toLocaleDateString())}</td><td><button data-use-project="${esc(project.id)}">Use in quotation</button>${canDelete ? ` <button class="danger" data-delete-project="${esc(project.id)}">Delete</button>` : ""}</td></tr>`;
            })
            .join("") || '<tr><td colspan="4" class="muted">No shared projects yet.</td></tr>';
      }

      function renderProjectSubcategories() {
        const categories = products
          .filter((product) => product.category === $("projectCategory").value)
          .map((product) => product.subcategory)
          .filter(Boolean);
        options(
          "projectSubcategory",
          [...new Set(categories)].map((subcategory) => ({
            value: subcategory,
            label: subcategory,
          })),
        );
        renderProjectProducts();
      }

      function renderProjectProducts() {
        options(
          "projectProduct",
          products
            .filter(
              (product) =>
                product.category === $("projectCategory").value &&
                product.subcategory === $("projectSubcategory").value,
            )
            .map((product) => ({
              value: product.id,
              label: `${product.part} — ${product.description}`,
            })),
        );
      }

      function renderProjectDraft() {
        $("projectDraftRows").innerHTML =
          projectDraftLines
            .map((item, index) => {
              const product = products.find((entry) => entry.id === item.product_id);
              if (!product) return "";
              return `<tr><td>${esc(product.part)}</td><td>${esc(product.description)}</td><td>${esc(item.qty)}</td><td><button data-remove-project-item="${index}">Remove</button></td></tr>`;
            })
            .join("") ||
          '<tr><td colspan="4" class="muted">Add products to build this project.</td></tr>';
      }

      async function saveProjectTemplate(name, items) {
        const projectName = String(name || "").trim();
        if (!projectName) throw Error("Enter a project name");
        if (!Array.isArray(items) || !items.length)
          throw Error("Add at least one product to the project");
        const projectItems = items.map((item) => {
          if (!products.some((product) => product.id === item.product_id))
            throw Error("Projects can only include active products from the product database");
          const qty = Number(item.qty);
          if (!Number.isSafeInteger(qty) || qty <= 0)
            throw Error("Project product quantities must be positive whole numbers");
          return { product_id: item.product_id, qty };
        });
        checked(
          await db.from("projects").insert({
            name: projectName,
            items: projectItems,
            created_by: user.id,
          }),
        );
      }

      $("projectCategory").onchange = renderProjectSubcategories;
      $("projectSubcategory").onchange = renderProjectProducts;
      $("addProjectProduct").onclick = () => {
        const product = products.find((entry) => entry.id === $("projectProduct").value);
        const qty = Number($("projectProductQty").value);
        if (!product) return notify("Select a product to add to the project", true);
        if (!Number.isSafeInteger(qty) || qty <= 0)
          return notify("Enter a positive whole-number quantity", true);
        projectDraftLines.push({ product_id: product.id, qty });
        renderProjectDraft();
      };
      $("projectDraftRows").onclick = (event) => {
        const index = event.target.dataset.removeProjectItem;
        if (index === undefined) return;
        projectDraftLines.splice(Number(index), 1);
        renderProjectDraft();
      };
      $("clearProjectDraft").onclick = () => {
        projectDraftLines = [];
        $("projectName").value = "";
        $("projectProductQty").value = "1";
        renderProjectDraft();
      };
      $("saveProject").onclick = () =>
        safe(async () => {
          await saveProjectTemplate($("projectName").value, projectDraftLines);
          $("clearProjectDraft").click();
          await refresh();
          notify("Project saved for the whole team");
        });
      $("projectsRows").onclick = (event) =>
        safe(async () => {
          const useId = event.target.closest("[data-use-project]")?.dataset.useProject;
          if (useId) {
            const project = projects.find((entry) => entry.id === useId);
            if (!project) return;
            if ((lines.length || editQuote) && !confirm(
              "Using this project will replace the quotation currently in the editor and start a new quotation. Continue?",
            ))
              return;
            const items = Array.isArray(project.items) ? project.items : [];
            const unavailable = items.filter(
              (item) => !products.some((product) => product.id === item.product_id),
            );
            if (unavailable.length)
              throw Error(
                "This project contains products that are no longer active. Ask its creator or an administrator to replace those products.",
              );
            lines = items.map((item) => {
              const product = products.find((entry) => entry.id === item.product_id);
              const qty = Number(item.qty);
              if (!product || !Number.isSafeInteger(qty) || qty <= 0)
                throw Error("This project has an invalid product or quantity");
              return {
                product_id: product.id,
                part: product.part,
                description: product.description,
                supplier: product.supplier,
                qty,
                cost: Number(product.price),
              };
            });
            editQuote = null;
            $("quoteNo").value = "";
            $("quoteProjectName").value = project.name;
            $("quoteCustomer").value = "";
            $("quoteStatus").value = "Draft";
            $("quoteNotes").value = "";
            applyQuoteDefaults();
            document.querySelector('[data-tab="quotes"]').click();
            notify(`Project "${project.name}" loaded with current product prices. Adjust its items for this quotation.`);
            return;
          }

          const deleteId = event.target.closest("[data-delete-project]")?.dataset.deleteProject;
          if (!deleteId) return;
          const project = projects.find((entry) => entry.id === deleteId);
          if (!project) return;
          if (!confirm(`Delete the shared project "${project.name}"?`)) return;
          checked(await db.from("projects").delete().eq("id", deleteId));
          await refresh();
          notify("Project deleted");
        });
