This is an upgrade project to bring vutuv, a legacy Phoenix application, up to the latest Elixir and Phoenix Framework.

vutuv is a classic Phoenix **controller + view + `.html.heex` template** app. It has **no LiveView**: there are no `live` routes, no `core_components.ex`, no `layouts.ex`, and no `Layouts.app`. It uses the legacy `Phoenix.View` layer (`lib/vutuv_web/views/*`). Do not reach for LiveView, `Phoenix.Component` layouts, or `core_components` patterns, and do not remove existing `Phoenix.View` usage, unless a task explicitly migrates that layer. See `README.md` for setup, architecture, and deployment.

Framework conventions (Elixir, Ecto, Phoenix, HEEx, LiveView, assets) live in `.claude/rules/` and load automatically only when you edit a matching file, so they stay out of context the rest of the time.

## Project guidelines

- Use the `mix test` alias when you are done with all changes and fix any pending issues (it runs `ecto.create` + `ecto.migrate` first).
- Use the already included `:req` (`Req`) library for HTTP requests; **avoid** `:httpoison`, `:tesla`, and `:httpc`.
- **Email is sent through one chokepoint.** Build every message from `Vutuv.Notifications.Emailer.base_email/0` and send it with `Emailer.deliver/1`. **Never** call `Vutuv.Mailer.deliver/1` or use `Swoosh` directly outside `Vutuv.Notifications.Emailer`. `base_email/0` stamps the `From` and the auto-generated robot headers (`Auto-Submitted`, `X-Auto-Response-Suppress`) that keep out-of-office responders silent. Builders **return** a `%Swoosh.Email{}`; the single `deliver/1` sends it. A regression test (`test/vutuv/notifications/mailer_chokepoint_test.exs`) fails the build if anything bypasses this. For bulk mail, add `Emailer.bulk_headers/1`.
