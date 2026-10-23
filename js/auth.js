      function applyQuoteDefaults() {
        [
          ["markup", "markup"],
          ["laborRate", "labor_rate"],
          ["tax", "tax_rate"],
          ["laborHours", "labor_hours"],
        ].forEach(([id, key]) => ($(id).value = quoteDefaults[key]));
        renderLines();
      }
      function renderDefaultInputs() {
        [
          ["defaultMarkup", "markup"],
          ["defaultLaborRate", "labor_rate"],
          ["defaultTax", "tax_rate"],
          ["defaultLaborHours", "labor_hours"],
        ].forEach(([id, key]) => ($(id).value = quoteDefaults[key]));
      }
      async function loadQuoteDefaults() {
        const { data, error } = await db
          .from("quote_settings")
          .select("markup,labor_rate,tax_rate,labor_hours")
          .eq("id", 1)
          .maybeSingle();
        if (error) {
          $("settingsHelp").textContent =
            "Settings unavailable: run the supplied SQL setup in Supabase first.";
          notify("Quotation defaults could not load: " + error.message, true);
          return;
        }
        if (data) quoteDefaults = { ...quoteDefaults, ...data };
        renderDefaultInputs();
        applyQuoteDefaults();
        $("settingsHelp").textContent = "Defaults are stored in Supabase.";
      }
      $("saveDefaults").onclick = () =>
        safe(async () => {
          if (profile?.role !== "admin") throw Error("Admin required to change company defaults");
          const values = {
            markup: Number($("defaultMarkup").value),
            labor_rate: Number($("defaultLaborRate").value),
            tax_rate: Number($("defaultTax").value),
            labor_hours: Number($("defaultLaborHours").value),
          };
          if (
            Object.entries(values).some(
              ([k, v]) =>
                !Number.isFinite(v) ||
                v < 0 ||
                $(
                  "default" +
                    {
                      markup: "Markup",
                      labor_rate: "LaborRate",
                      tax_rate: "Tax",
                      labor_hours: "LaborHours",
                    }[k],
                ).value.trim() === "",
            )
          )
            throw Error("Enter valid nonnegative values");
          checked(await db.from("quote_settings").upsert({ id: 1, ...values }));
          quoteDefaults = values;
          notify("Quotation defaults saved. They will be used for new quotations.");
          $("settingsHelp").textContent = "Saved to Supabase.";
        });
      async function loadEstimateNumberSettings() {
        const { data, error } = await db.rpc("get_estimate_number_settings");
        if (error) {
          $("estimateNumberHelp").textContent =
            "Estimate numbering unavailable: apply the estimate-numbering migration in Supabase.";
          notify("Estimate numbering settings could not load: " + error.message, true);
          return;
        }
        $("estimatePrefix").value = data.prefix;
        $("estimateSerialWidth").value = data.serial_width;
        $("estimateNumberHelp").textContent =
          `Next serial: ${data.next_serial}. Existing saved quotations were checked when numbering was initialized.`;
      }
      $("saveEstimateNumberSettings").onclick = () =>
        safe(async () => {
          if (profile?.role !== "admin")
            throw Error("Admin required to change estimate numbering");
          const prefix = $("estimatePrefix").value.trim().toUpperCase();
          const serialWidth = Number($("estimateSerialWidth").value);
          if (!/^[A-Z][A-Z0-9]{0,11}$/.test(prefix))
            throw Error("Prefix must start with a letter and contain only letters and numbers");
          if (!Number.isSafeInteger(serialWidth) || serialWidth < 1 || serialWidth > 8)
            throw Error("Serial number digits must be between 1 and 8");
          const { data, error } = await db.rpc("save_estimate_number_settings", {
            p_prefix: prefix,
            p_serial_width: serialWidth,
          });
          if (error) throw error;
          $("estimatePrefix").value = data.prefix;
          $("estimateSerialWidth").value = data.serial_width;
          $("estimateNumberHelp").textContent =
            `Saved in Supabase. The serial continues globally; the next serial is ${data.next_serial}.`;
          notify("Estimate numbering settings saved");
        });
      let pendingMfaFactor = null,
        pendingEnrollFactor = null;
      function showOnlyAuth(id) {
        ["login", "forgotPanel", "mfaLogin", "passwordSetup", "app"].forEach((x) =>
          $(x).classList.toggle("hidden", x !== id),
        );
      }
      $("forgotPassword").onclick = () => {
        $("recoveryEmail").value = $("email").value.trim();
        showOnlyAuth("forgotPanel");
      };
      $("backToLogin").onclick = () => showOnlyAuth("login");
      $("forgotForm").onsubmit = (e) => {
        e.preventDefault();
        safe(async () => {
          const email = $("recoveryEmail").value.trim();
          if (!email) throw Error("Enter your email address");
          const redirectTo = new URL("./", window.location.href);
          redirectTo.searchParams.set("type", "recovery");
          const { error } = await db.auth.resetPasswordForEmail(email, {
            redirectTo: redirectTo.href,
          });
          if (error) throw error;
          notify(
            "If the account exists, a password reset link has been sent. Check your inbox and spam folder.",
          );
          showOnlyAuth("login");
        });
      };
      async function mfaCheck() {
        const { data, error } = await db.auth.mfa.getAuthenticatorAssuranceLevel();
        if (error) throw error;
        if (data.nextLevel === "aal2" && data.currentLevel !== "aal2") {
          const factors = checked(await db.auth.mfa.listFactors()).totp || [];
          pendingMfaFactor = factors.find((f) => f.status === "verified")?.id;
          if (!pendingMfaFactor)
            throw Error("No verified authenticator found. Contact your administrator.");
          showOnlyAuth("mfaLogin");
          return false;
        }
        return true;
      }
      async function updateMfaStatus() {
        const { data, error } = await db.auth.mfa.listFactors();
        if (error) throw error;
        const factor = (data.totp || []).find((f) => f.status === "verified");
        $("mfaStatus").textContent = factor
          ? "Enabled — authenticator required at sign-in."
          : "Not enabled — you can activate an authenticator app.";
        $("mfaEnroll").classList.toggle("hidden", !!factor);
        $("mfaDisable").classList.toggle("hidden", !factor);
        return factor;
      }
      $("mfaLoginForm").onsubmit = (e) => {
        e.preventDefault();
        safe(async () => {
          const code = $("mfaLoginCode").value.trim();
          const challenge = checked(await db.auth.mfa.challenge({ factorId: pendingMfaFactor }));
          checked(
            await db.auth.mfa.verify({
              factorId: pendingMfaFactor,
              challengeId: challenge.id,
              code,
            }),
          );
          $("mfaLoginCode").value = "";
          await loadSession();
        });
      };
      $("mfaCancel").onclick = () =>
        safe(async () => {
          checked(await db.auth.signOut());
          pendingMfaFactor = null;
          showOnlyAuth("login");
        });
      $("mfaEnroll").onclick = () =>
        safe(async () => {
          const data = checked(
            await db.auth.mfa.enroll({
              factorType: "totp",
              friendlyName: "Quote Studio authenticator",
            }),
          );
          pendingEnrollFactor = data.id;
          const qr = data.totp.qr_code;
          if (!qr || !qr.startsWith("data:image/svg+xml;")) throw Error("Invalid QR code returned");
          const img = document.createElement("img");
          img.alt = "Authenticator setup QR code";
          img.style.width = "100%";
          img.src = qr;
          $("mfaQr").replaceChildren(img);
          $("mfaSecret").textContent = data.totp.secret;
          $("mfaEnrollment").classList.remove("hidden");
        });
      $("mfaEnrollForm").onsubmit = (e) => {
        e.preventDefault();
        safe(async () => {
          if (!pendingEnrollFactor) throw Error("Start enrollment first");
          const challenge = checked(await db.auth.mfa.challenge({ factorId: pendingEnrollFactor }));
          checked(
            await db.auth.mfa.verify({
              factorId: pendingEnrollFactor,
              challengeId: challenge.id,
              code: $("mfaEnrollCode").value.trim(),
            }),
          );
          pendingEnrollFactor = null;
          $("mfaEnrollCode").value = "";
          $("mfaEnrollment").classList.add("hidden");
          $("mfaQr").replaceChildren();
          $("mfaSecret").textContent = "";
          await updateMfaStatus();
          notify("Two-factor authentication enabled");
        });
      };
      $("mfaEnrollCancel").onclick = () =>
        safe(async () => {
          if (pendingEnrollFactor)
            checked(await db.auth.mfa.unenroll({ factorId: pendingEnrollFactor }));
          pendingEnrollFactor = null;
          $("mfaEnrollment").classList.add("hidden");
          $("mfaQr").replaceChildren();
          $("mfaSecret").textContent = "";
        });
      $("mfaDisable").onclick = () => {
        $("mfaDisablePanel").classList.toggle("hidden");
      };
      $("mfaDisableForm").onsubmit = (e) => {
        e.preventDefault();
        safe(async () => {
          const factor = await updateMfaStatus();
          if (!factor) throw Error("No verified authenticator");
          const challenge = checked(await db.auth.mfa.challenge({ factorId: factor.id }));
          checked(
            await db.auth.mfa.verify({
              factorId: factor.id,
              challengeId: challenge.id,
              code: $("mfaDisableCode").value.trim(),
            }),
          );
          checked(await db.auth.mfa.unenroll({ factorId: factor.id }));
          $("mfaDisableCode").value = "";
          $("mfaDisablePanel").classList.add("hidden");
          await updateMfaStatus();
          notify("Two-factor authentication disabled");
        });
      };
      async function loadSession() {
        if (passwordSetupMode) {
          showPasswordSetup();
          return;
        }
        const {
          data: { session },
        } = await db.auth.getSession();
        user = session?.user || null;
        if (!user) {
          showOnlyAuth("login");
          return;
        }
        if (!(await mfaCheck())) return;
        const result = await db.from("profiles").select("*").eq("id", user.id).maybeSingle();
        profile = checked(result);
        if (!profile) {
          notify(
            "Account has no employee profile. Ask the administrator to add your user ID: " +
              user.id,
            true,
          );
          await db.auth.signOut();
          return;
        }
        showOnlyAuth("app");
        $("identity").textContent = `${user.email} · ${profile.role}`;
        document
          .querySelector('[data-tab="team"]')
          .classList.toggle("hidden", profile.role !== "admin");
        $("saveProduct").disabled = profile.role !== "admin";
        $("saveDefaults").disabled = profile.role !== "admin";
        $("saveEstimateNumberSettings").disabled = profile.role !== "admin";
        $("estimatePrefix").disabled = profile.role !== "admin";
        $("estimateSerialWidth").disabled = profile.role !== "admin";
        await refresh();
        await loadQuoteDefaults();
        await loadEstimateNumberSettings();
        await updateMfaStatus();
      }
      // A recovery/invite link authenticates a temporary session; do not show the app until the password is set.
      db.auth.onAuthStateChange((event) => {
        if (event === "PASSWORD_RECOVERY") {
          passwordSetupMode = true;
          showPasswordSetup();
        } else if (event === "SIGNED_IN" && passwordSetupMode) {
          showPasswordSetup();
        }
      });
      if (passwordSetupMode) showPasswordSetup();
      async function getRecoverySession() {
        let {
          data: { session },
        } = await db.auth.getSession();
        if (session) return session;

        const callbackUrl = new URL(window.location.href);
        const code = callbackUrl.searchParams.get("code");
        if (code) {
          const result = await db.auth.exchangeCodeForSession(code);
          if (result.error) throw result.error;
          session = result.data.session;
        } else {
          const fragment = new URLSearchParams(callbackUrl.hash.slice(1));
          const accessToken = fragment.get("access_token");
          const refreshToken = fragment.get("refresh_token");
          if (accessToken && refreshToken) {
            const result = await db.auth.setSession({
              access_token: accessToken,
              refresh_token: refreshToken,
            });
            if (result.error) throw result.error;
            session = result.data.session;
          } else {
            const tokenHash =
              callbackUrl.searchParams.get("token_hash") || fragment.get("token_hash");
            if (!tokenHash) return null;
            const result = await db.auth.verifyOtp({ token_hash: tokenHash, type: "recovery" });
            if (result.error) throw result.error;
            session = result.data.session;
          }
        }
        return session;
      }
      $("passwordSetupForm").onsubmit = (e) => {
        e.preventDefault();
        safe(async () => {
          const pass = $("newPassword").value,
            confirmation = $("confirmPassword").value;
          if (pass.length < 8) throw Error("Use a password with at least 8 characters");
          if (pass !== confirmation) throw Error("The passwords do not match");
          const session = await getRecoverySession();
          if (!session)
            throw Error(
              "This page did not receive valid recovery credentials. Request a new reset link and open it in the same browser. If the issue continues, ask your administrator to check Supabase's email template and redirect URL settings.",
            );
          const { error } = await db.auth.updateUser({ password: pass });
          if (error) throw error;
          // End the temporary session so the employee signs in with the password they chose.
          checked(await db.auth.signOut());
          passwordSetupMode = false;
          history.replaceState(null, "", location.pathname);
          $("newPassword").value = "";
          $("confirmPassword").value = "";
          showOnlyAuth("login");
          notify("Password saved. Sign in using your new password.");
        });
      };
      $("signIn").onclick = () =>
        safe(async () => {
          checked(
            await db.auth.signInWithPassword({
              email: $("email").value.trim(),
              password: $("password").value,
            }),
          );
          await loadSession();
        });
      $("signOut").onclick = () =>
        safe(async () => {
          await db.auth.signOut();
          location.reload();
        });
      document.querySelectorAll("[data-tab]").forEach(
        (b) =>
          (b.onclick = () => {
            document
              .querySelectorAll("[data-tab]")
              .forEach((x) => x.classList.toggle("active", x === b));
            ["quotes", "shiftReports", "projects", "products", "customers", "inventory", "team", "settings"].forEach((x) =>
              $(x).classList.toggle("hidden", x !== b.dataset.tab),
            );
          }),
      );
