---
paths:
  - "**/*_live.ex"
  - "**/*_live.exs"
---

<!--
  These rules load when you edit a *_live.ex module. They cost no context the rest
  of the time. The generic LiveView guidance below (streams, JS interop, hooks,
  tests, forms) applies as written; the "vutuv specifics" section corrects the
  stock Phoenix-1.8 assumptions that do NOT hold in this codebase.
-->

## vutuv specifics (read first — these override the generic notes below)

LiveView is adopted **incrementally** here; it is not a fresh `phx.gen.auth` app.
The live modules in `lib/vutuv_web/live/`: `ShellLive` (the chrome), `MemberCountLive`
(landing pill), `SearchLive`, `PostLive.Feed`, `PostLive.Edit`, `PostLive.Reply`,
`PostLive.Saved`, `PostLive.Composer` (a LiveComponent), the post action bar
(`PostLive.ActionsComponent`, an in-process LiveComponent on LiveView host pages;
`PostLive.Actions`, the standalone `live_render` bar kept only for the dead controller
pages — both render `PostComponents.post_actions/1` and share `PostLive.ActionBar`),
`MessageLive.Index`, `NotificationLive.Index`, `UserProfileLive` (the member profile
`/:slug`), plus the `on_mount` hooks `Live.InitAssigns` and `LiveLocale`.

- **The profile (`UserProfileLive`) is embedded by a controller, not a `live/3` route.**
  `VutuvWeb.UserController.show` keeps owning agent-format negotiation (the `.md`/`.txt`/
  `.json`/`.xml`/`.vcf` siblings via `ProfileDoc`) and, for HTML, calls
  `live_render(conn, UserProfileLive, …)` after `put_layout(html: false)` (so the `:app`
  layout — ShellLive included — renders once, from the LiveView, not twice). Because it is
  off-router it **cannot** use `Live.InitAssigns` as its `on_mount` (that hook attaches a
  `:handle_params` hook, which an off-router LiveView rejects) and has no `handle_params`,
  so `?view_as=` stays a full reload; mount mirrors InitAssigns (current_user + locale) and
  reads the path/locale/profile id/view_as from the session the controller passes. It
  renders the one profile markup — `VutuvWeb.UserHTML.show/1` (the embedded
  `templates/user/show.html.heex`) — so keep `ProfileDoc` in sync (drift test). The header
  **Every state-changing control is `phx-click`, handled here, no reload:** the header
  follow pill, the tag-endorsement pills, the ⋯-menu Mute/Bookmark/Like/Block and the
  Unblock control, the follower/following/who-to-follow `user_row` follow buttons, and the
  owner "View as" switcher — all pass `live?` to their `VutuvWeb.UI` components
  (`follow_button`/`follow_relationship`/`tag_vote`/`card_menu`/`user_row`/`view_as_switcher`).
  Counts and tags also update live over PubSub (see the social-graph note below). The
  **post action bars** are in-process `PostLive.ActionsComponent`s here (not their own
  `live_render` — that flashed on every stream re-render), and the profile drops a deleted
  post live via `{:post_deleted}` on the owner's topic. What stays a plain `<a>` is
  **navigation** (Message, Report, vCard, agent-format/map/manage/edit links) and the shared
  **post card ⋯ menu** (classic everywhere incl. the feed — don't special-case it on the
  profile). The classic CSRF routes (Follow/UserSave/Block/UserTagEndorsement
  controllers) stay as the no-JS / API path.

- **There is no `core_components.ex`.** Do **not** use `<.input>`, `<.icon name="hero-…">`,
  or `<Layouts.app>` — they don't exist. Use the **`VutuvWeb.UI`** components (imported
  everywhere) and the recipes in `.claude/rules/design.md`; that design rule is the
  source of truth for every visual choice. Read it before touching a LiveView template.
- **No `<Layouts.app>` wrapper and no `<.flash_group>`.** The chrome (sticky top bar +
  mobile bottom tab bar with live badges) is `VutuvWeb.ShellLive`, embedded once in
  `app.html.heex`. Pages render **inside** it; never add their own nav. Flash is shown
  as top-right toasts (`#toast-tray` in `app.html.heex`) — never add inline flash banners.
- **No `current_scope`.** Authentication assigns flow through `VutuvWeb.Live.InitAssigns`
  (`:current_user`, `:current_user_id`) wired as the `on_mount` for the `live_session`.
  A LiveView that must require a login checks `current_user` in `mount/3`; there is no
  `current_scope` assign and routes are not auto-scoped by it.
- **Gettext locale is per process.** `VutuvWeb.LiveLocale` re-applies the session locale
  on mount (called from `Live.InitAssigns` and `ShellLive.mount`). A LiveView mounted
  **outside** the `live_session` must call it too, or the whole shared chrome silently
  falls back to English.
- **Real-time** goes through `Vutuv.Activity` (`Phoenix.PubSub` on `"user:<id>"` and
  `"post:<id>"`) and `VutuvWeb.Presence` — not ad-hoc `Phoenix.PubSub` topics. The
  profile listens for two events on the owner's `"user:<id>"` topic:
  `{:social_graph_changed, _}` (broadcast by `Vutuv.Social.follow/2` + `unfollow!/2` to both
  members, so a follow/unfollow anywhere recomputes the counts + pill) and
  `{:endorsement_changed, user_tag_id}` (broadcast by `Vutuv.Tags.create_endorsement/1` +
  `delete_endorsement/2` to the tag owner). Any new message type added to `"user:<id>"`
  must be tolerated by **every** subscriber of that topic — ShellLive, MessageLive,
  NotificationLive, PostLive.Feed/Saved and UserProfileLive all keep a catch-all
  `handle_info(_other, socket)`; keep it that way.
- **Icons** are either CSS glyphs (`i.icon.icon--…`, styled in `components.css`) or the
  shared `VutuvWeb.UI` SVG components (`<.icon_repost>`, `<.icon_reply>`,
  `<.icon_bookmark>`); icons used by a single LiveView stay private to it. Never pull in
  `Heroicons`.
- **Forms** use `<.form for={@form} …>` + `to_form/2` (see below). For inputs, vutuv has
  no `<.input>`; style raw inputs with `class={input_class()}`
  (`VutuvWeb.UI.input_class/0`) / `checkbox_class/0`, and nest with `<.inputs_for>`.

## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

- **To select a descendant element from a full page, use `LazyHTML.query/2`, never `LazyHTML.filter/2`.** `filter/2` only matches the *root* nodes of the current node set — on a `from_document/1` page that is `<html>`, so `LazyHTML.filter(doc, "#some-id")` silently returns an empty set (and an empty set makes `refute LazyHTML.text(...) =~ "..."` pass vacuously). `query/2` searches the whole subtree. Reach for `filter/2` only to narrow a node set you already queried.

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
