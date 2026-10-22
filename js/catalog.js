      function options(id, arr, placeholder = "Select") {
        const previous = $(id).value;
        $(id).innerHTML =
          '<option value="">' +
          esc(placeholder) +
          "</option>" +
          arr.map((x) => `<option value="${esc(x.value)}">${esc(x.label)}</option>`).join("");
        if (arr.some((x) => String(x.value) === previous)) $(id).value = previous;
      }
      function renderAll() {
        renderProducts();
        renderCustomers();
        renderQuotes();
        renderInventory();
        $("teamRows").innerHTML = team
          .map(
            (p) =>
              `<tr><td>${esc(p.id)}</td><td>${esc(p.full_name)}</td><td>${esc(p.role)}</td></tr>`,
          )
          .join("");
      }
      function renderProducts() {
        const t = $("productSearch").value.toLowerCase();
        $("productRows").innerHTML = products
          .filter((p) => (p.part + p.description + p.category).toLowerCase().includes(t))
          .map(
            (p) =>
              `<tr><td>${esc(p.part)}</td><td>${esc(p.category)} / ${esc(p.subcategory)}</td><td>${esc(p.description)}</td><td>${esc(p.supplier)}</td><td>${money(p.price)}</td><td>${profile.role === "admin" ? `<button data-edit-product="${p.id}">Edit</button> <button data-delete-product="${p.id}" class="danger">Archive</button>` : ""}</td></tr>`,
          )
          .join("");
        options(
          "stockProduct",
          products.map((p) => ({ value: p.id, label: p.part + " — " + p.description })),
        );
        const cats = [...new Set(products.map((p) => p.category))].sort();
        options(
          "cat",
          cats.map((x) => ({ value: x, label: x })),
        );
        renderSubs();
      }
      function renderSubs() {
        const subs = [
          ...new Set(
            products.filter((p) => p.category === $("cat").value).map((p) => p.subcategory),
          ),
        ].sort();
        options(
          "sub",
          subs.map((x) => ({ value: x, label: x })),
        );
        renderPicks();
      }
      function renderPicks() {
        options(
          "pickProduct",
          products
            .filter((p) => p.category === $("cat").value && p.subcategory === $("sub").value)
            .map((p) => ({ value: p.id, label: p.part + " — " + p.description })),
        );
      }
      $("cat").onchange = renderSubs;
      $("sub").onchange = renderPicks;
      $("productSearch").oninput = renderProducts;
      $("productRows").onclick = (e) => {
        const id = e.target.dataset.editProduct || e.target.dataset.deleteProduct;
        if (!id) return;
        const p = products.find((x) => x.id === id);
        if (e.target.dataset.editProduct) {
          editProduct = id;
          ["Part", "Category", "Sub", "Description", "Supplier", "Price"].forEach(
            (field, i) =>
              ($("prod" + field).value = [
                p.part,
                p.category,
                p.subcategory,
                p.description,
                p.supplier,
                p.price,
              ][i]),
          );
        } else
          safe(async () => {
            if (!confirm("Archive this product? Historical quotes and stock records will remain."))
              return;
            checked(await db.from("products").update({ active: false }).eq("id", id));
            await refresh();
          });
      };
      $("resetProduct").onclick = () => {
        editProduct = null;
        ["Part", "Category", "Sub", "Description", "Supplier", "Price"].forEach(
          (f) => ($("prod" + f).value = ""),
        );
      };
      $("saveProduct").onclick = () =>
        safe(async () => {
          if (profile.role !== "admin") throw Error("Admin required");
          const row = {
            part: $("prodPart").value.trim(),
            category: $("prodCategory").value.trim(),
            subcategory: $("prodSub").value.trim(),
            description: $("prodDescription").value.trim(),
            supplier: $("prodSupplier").value.trim(),
            price: Number($("prodPrice").value),
          };
          if (!row.part || !row.description || !Number.isFinite(row.price) || row.price < 0)
            throw Error("Part, description and valid price required");
          if (editProduct) checked(await db.from("products").update(row).eq("id", editProduct));
          else checked(await db.from("products").insert(row));
          $("resetProduct").click();
          await refresh();
          notify("Product saved");
        });
      function renderCustomers() {
        options(
          "quoteCustomer",
          customers.map((c) => ({ value: c.id, label: c.name })),
        );
        $("customerRows").innerHTML = customers
          .map(
            (c) =>
              `<tr><td>${esc(c.name)}</td><td>${esc(c.contact)}</td><td>${esc(c.email)}</td><td>${esc(c.phone)}</td><td><button data-edit-customer="${c.id}">Edit</button></td></tr>`,
          )
          .join("");
      }
      $("customerRows").onclick = (e) => {
        const id = e.target.dataset.editCustomer;
        if (!id) return;
        const c = customers.find((x) => x.id === id);
        editCustomer = id;
        ["Name", "Contact", "Email", "Phone", "Address", "Notes"].forEach(
          (f) => ($("cust" + f).value = c[f.toLowerCase()] || ""),
        );
      };
      $("resetCustomer").onclick = () => {
        editCustomer = null;
        ["Name", "Contact", "Email", "Phone", "Address", "Notes"].forEach(
          (f) => ($("cust" + f).value = ""),
        );
      };
      $("saveCustomer").onclick = () =>
        safe(async () => {
          const row = Object.fromEntries(
            ["name", "contact", "email", "phone", "address", "notes"].map((f) => [
              f,
              $("cust" + f[0].toUpperCase() + f.slice(1)).value.trim(),
            ]),
          );
          if (!row.name) throw Error("Customer name required");
          if (editCustomer) checked(await db.from("customers").update(row).eq("id", editCustomer));
          else checked(await db.from("customers").insert(row));
          $("resetCustomer").click();
          await refresh();
          notify("Customer saved");
        });
      $("addLine").onclick = () => {
        const p = products.find((p) => p.id === $("pickProduct").value),
          qty = Number($("pickQty").value);
        if (!p || !Number.isSafeInteger(qty) || qty <= 0)
          return notify("Select a product and positive quantity", true);
        lines.push({
          product_id: p.id,
          part: p.part,
          description: p.description,
          supplier: p.supplier,
          qty,
          cost: Number(p.price),
        });
        renderLines();
      };
