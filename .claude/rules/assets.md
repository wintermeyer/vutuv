---
paths:
  - "assets/**"
  - "**/*.heex"
---

## JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/vutuv_web";

- **Always use and maintain this import syntax** in the app.css file.
- **The `once(el, key)` "wire once" guard writes `key` into `el.dataset`, so `key` MUST be a single word or camelCase — never contain a hyphen.** `once` does `el.dataset["wired_" + key]`, and a hyphen makes an invalid `DOMStringMap` property name, so `once(box, "organization-link")` throws `SyntaxError: 'wired_organization-link' is not a valid property name` at setup time and the **whole** enhancement silently never wires (the feature just doesn't work, no visible error unless you read the console). Every existing key is single-word/camelCase (`slug`, `tagVote`, `charCounter`, `employmentVisibility`) — match that (`organizationLink`, not `organization-link`). This shipped a dead work-experience→organization link suggestion until a browser smoke test surfaced the console exception.
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**
- **Never put `hidden` on the same element as another `display` utility (`inline-block`/`block`/`flex`/`grid`) for a toggle-based show/hide.** Both set `display` with equal specificity, so the one Tailwind emits *later* in the bundle wins the cascade — and `.inline-block`/`.block`/`.flex` are emitted *after* `.hidden`, so `hidden` silently fails to hide (`getComputedStyle(el).display` stays `inline-block`, the class is present but inert). This shipped the #880 "Weiterlesen shows on every post" bug for months and defeated three JS "fixes" because the toggled `hidden` was a no-op. Instead keep the two classes **mutually exclusive**: render exactly one from the server (`if(cond, do: "inline-block", else: "hidden")`, no static display utility) and, if JS flips it at runtime, toggle **both** (`el.classList.toggle("hidden", off); el.classList.toggle("inline-block", !off)`). When debugging any "wrongly visible/hidden" element, confirm with a **screenshot + `getComputedStyle(el).display`**, never `classList.contains("hidden")` — a class can be present but overridden.
