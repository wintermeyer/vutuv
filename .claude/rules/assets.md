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
- **Clamping *formatted* prose (rendered Markdown) to N lines needs a height clamp, not `-webkit-line-clamp` — and the height math only works if you neutralize block margins and type size inside the clamp.** `-webkit-line-clamp` needs a `display: -webkit-box`, which clamps block children (`<p>`, `<ul>`) unreliably, so a Markdown body clamps with `display: flow-root; overflow: hidden; max-height: calc(N * 1lh)` (`.post-clamp--wrap`, `.notif-clamp`). Two traps make that box show **fewer** lines than N, both hit while formatting the /notifications quotes: (1) `.markdown`'s block spacing (`p`/`ul` `margin-bottom: 0.75em`, `li` `0.2em`) is counted out of the budget, so zero it inside the clamp; (2) `1lh` resolves against the **container's** line-height, but Tailwind's `text-sm` line-height is a **unitless ratio** that inherits, so any descendant with a different font-size renders a taller line — and `components.css` sets a global element default `p { font-size: 15px }`, which alone is enough to overflow a five-line box by one line. Give the clamped block `font-size: inherit; line-height: inherit` on its descendants. And watch specificity: a bare `.myclamp > *` (0,1,0) **loses** to `.markdown p` (0,1,1), so name both classes (`.myclamp.markdown > *`). Verify in a browser with `scrollHeight` vs `clientHeight` on the clamp element — they should match when the content is exactly N lines.
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**
- **Never put `hidden` on the same element as another `display` utility (`inline-block`/`block`/`flex`/`grid`) for a toggle-based show/hide.** Both set `display` with equal specificity, so the one Tailwind emits *later* in the bundle wins the cascade — and `.inline-block`/`.block`/`.flex` are emitted *after* `.hidden`, so `hidden` silently fails to hide (`getComputedStyle(el).display` stays `inline-block`, the class is present but inert). This shipped the #880 "Weiterlesen shows on every post" bug for months and defeated three JS "fixes" because the toggled `hidden` was a no-op. Instead keep the two classes **mutually exclusive**: render exactly one from the server (`if(cond, do: "inline-block", else: "hidden")`, no static display utility) and, if JS flips it at runtime, toggle **both** (`el.classList.toggle("hidden", off); el.classList.toggle("inline-block", !off)`). When debugging any "wrongly visible/hidden" element, confirm with a **screenshot + `getComputedStyle(el).display`**, never `classList.contains("hidden")` — a class can be present but overridden.
