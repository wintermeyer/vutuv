---
paths:
  - "lib/**/*.ex"
---

<!--
  Project note: vutuv is a legacy controller/view/template app and DOES use the
  Phoenix view layer (lib/vutuv_web/views/*, 49 view modules). The generic
  "Phoenix.View no longer is needed, don't use it" rule below comes from upstream
  usage_rules and does NOT apply to this codebase until the view layer is migrated.
  Do not remove existing Phoenix.View usage.
-->

## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
