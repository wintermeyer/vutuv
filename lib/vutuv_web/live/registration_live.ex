defmodule VutuvWeb.RegistrationLive do
  @moduledoc """
  The sign-up form on `/`, in three steps: name and address, then the settings,
  then the topics (issue: the one-screen form asked eleven things at once).

  **It collects; it does not create.** Everything the member types lives in this
  socket until the last step, whose button submits a plain
  `POST /new_registration` — the same endpoint, the same
  `Vutuv.Accounts.register_user/2`, the same CSRF token and the same PIN screen
  as before. Nothing about account creation moved into a socket, so the flow
  that mails a login PIN to an address somebody else typed is exactly the
  reviewed one. A rejected submit still re-renders the old single-screen form
  with its errors (`VutuvWeb.PageController.new_registration/2`), which is the
  one seam this split leaves behind.

  Two consequences of that shape are worth knowing before changing anything
  here:

    * **One `<form>` wraps all three steps.** The visible fields of the current
      step post under `step[...]` and feed `phx-change`; every value that the
      final POST needs is rendered as a hidden `user[...]` input from socket
      state, on every step. So there is exactly one place that decides what gets
      posted, and "Weiter" is a `phx-click` button rather than a submit.
    * **The browser's time zone field is rendered from step 1 and carries
      `phx-update="ignore"`.** `app.js` fills `[data-timezone-field]` once on
      page load (issue #1502); a field that only appeared on step 3 would never
      be filled, and one LiveView re-renders would be blanked again. Without it
      a new account silently keeps Berlin time.

  The number beside each tag is the point of the third step, and it comes from
  `Vutuv.Tags.member_counts_by_name/1`. The sum of the selection was shown under
  it for a day and taken out again (Stefan, 2026-09-19); if it ever comes back,
  it must not be the chips added up — one member holding two of the tags is two
  chips and one person — so it needs its own `DISTINCT`, which is what
  `member_reach_by_name/1` was. The suggestions are loaded when step 3 is first
  reached, never on mount: `/` is the page every crawler gets, and the post wall
  that used to open a socket here came out again for what it cost
  (`test/vutuv_web/landing_page_test.exs`).
  """

  use VutuvWeb, :embedded_live_view

  import VutuvWeb.UserHelpers, only: [gender_options: 0]

  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Prefs
  alias Vutuv.Tags
  alias VutuvWeb.ErrorHelpers
  alias VutuvWeb.LiveLocale

  # How many suggested topics the third step offers. Twelve is what
  # `Tags.popular_member_tags/1` defaults to and fills about three rows on a
  # phone.
  @suggestion_limit 12

  @impl true
  def mount(_params, session, socket) do
    # Off-router, so nothing has applied the viewer's language and clock to this
    # process: an embedded LiveView that skips this renders English on a German
    # page (the rule in `.claude/rules/liveview.md`, learned the hard way by the
    # shared chrome). There is never a member here — this form exists to create
    # one — so the session is the only source.
    LiveLocale.put_viewer(session)

    {:ok,
     socket
     # The token is taken from the HTTP request that rendered this child rather
     # than minted here: the final POST is an ordinary browser form submit and
     # has to carry the token of the visitor's own session. It is no secret —
     # the same value sits in every rendered form on the page.
     |> assign(:csrf_token, session["csrf_token"])
     |> assign(:step, 1)
     |> assign(:tags, [])
     |> assign(:tag_counts, %{})
     |> assign(:tag_errors, tag_errors([]))
     |> assign(:suggestions, [])
     |> assign(:errors, [])
     |> assign(:fields, default_fields())
     |> restore(session["form_state"])}
  end

  # A rejected `POST /new_registration` renders this page again and hands back
  # what was posted (`PageController.rejected_form_state/2`). Reopening on the
  # topics step with the banner on it is the whole point: the member has just
  # filled in three screens, and a wizard that forgets them is worse than the
  # single screen it replaced.
  defp restore(socket, %{"params" => params, "errors" => errors}) when is_map(params) do
    fields =
      Map.new(socket.assigns.fields, fn {key, default} ->
        {key, restored_field(params, key, default)}
      end)

    socket
    |> assign(:fields, fields)
    |> assign(:errors, restored_errors(errors))
    |> assign(:step, 3)
    |> put_tags(Tags.parse_tag_names(Map.get(params, "tag_list", "")))
    |> load_suggestions(3)
  end

  defp restore(socket, _absent), do: socket

  # `[["tag_list", "…"], …]` as the signed session carries it. A field this form
  # does not render marks nothing, so its message shows on its own rather than
  # promising a red field nobody can find.
  @marked_fields ~w(first_name last_name email tag_list gender)

  defp restored_errors(errors) do
    for entry <- List.wrap(errors) do
      case entry do
        [field, message] when field in @marked_fields ->
          {String.to_existing_atom(field), message}

        [_field, message] ->
          {:base, message}

        message when is_binary(message) ->
          {:base, message}
      end
    end
  end

  # The two inverted flags travel as the columns they are (`noindex?`, `noai?`)
  # and are turned back into the positive question the box asks.
  defp restored_field(params, "search_engines", default),
    do: not truthy(params, "noindex?", not default)

  defp restored_field(params, "ai_agents", default), do: not truthy(params, "noai?", not default)

  defp restored_field(params, "fediverse", default),
    do: truthy(params, "fediverse_followers?", default)

  defp restored_field(params, "low_bandwidth", default),
    do: truthy(params, "low_bandwidth?", default)

  defp restored_field(params, "email_public", default),
    do: truthy(params, "email_public", default)

  defp restored_field(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> value
      _ -> default
    end
  end

  defp truthy(params, key, default) do
    case Map.fetch(params, key) do
      {:ok, value} -> checked?(value)
      :error -> default
    end
  end

  # The defaults are the ones the single-screen form shipped with, deliberately
  # unchanged: the address shows on the profile, search engines and AI agents
  # are allowed, the Fediverse box is ticked where the installation federates at
  # all, low-bandwidth mode is off, and the gender question starts UNSET — an
  # unset group asks, a preselected one assumes (see `PageController.index/2`,
  # which learned that from members writing in about it).
  defp default_fields do
    %{
      "first_name" => "",
      "last_name" => "",
      "email" => "",
      # nil, NOT "": the blank radio ("Keine Angabe") carries the value "",
      # so a form starting at "" would render that option preselected — and
      # an unset group asks while a preselected one assumes, which is the
      # whole reason this field was rebuilt once already. nil matches no
      # option, and picking the blank one really does store "".
      "gender" => nil,
      "email_public" => true,
      "search_engines" => true,
      "ai_agents" => true,
      "fediverse" => Fediverse.enabled?(),
      "low_bandwidth" => false,
      # The topic being typed. It rides the same field map as everything else
      # rather than a form of its own, because the whole wizard is ONE form and
      # a nested one is not valid HTML — so Enter cannot be a submit here.
      "typed" => ""
    }
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, socket |> merge_fields(params) |> absorb_finished_tags() |> assign(:errors, [])}
  end

  @impl true
  def handle_event("next", params, socket) do
    socket = merge_fields(socket, params)

    case validate_step(socket.assigns.step, socket.assigns.fields) do
      [] -> {:noreply, advance(socket)}
      errors -> {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def handle_event("back", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, max(socket.assigns.step - 1, 1))
     |> assign(:errors, [])}
  end

  @impl true
  def handle_event("add_tag", %{"name" => name}, socket) do
    {:noreply, socket |> put_tags(socket.assigns.tags ++ [name]) |> assign(:errors, [])}
  end

  # The typed field: one name or a whole comma-separated line, split the way a
  # save splits it, so "Elixir, Kochen" adds two topics rather than one topic
  # called "Elixir, Kochen".
  #
  # Two things reach here — Enter in the field and the button beside it — and
  # they carry the value differently: a `phx-keydown` brings the input's own
  # `value`, a `phx-click` brings nothing and the field map answers. Reading
  # both is what keeps Enter working ahead of the change event.
  @impl true
  def handle_event("add_typed", params, socket) do
    typed = params["value"] || socket.assigns.fields["typed"] || ""
    # What the hook left standing in the field, or nothing when Enter or the
    # button got here (both finish the whole field).
    rest = params["rest"] || ""

    {:noreply, socket |> absorb(typed, rest) |> assign(:errors, [])}
  end

  @impl true
  def handle_event("remove_tag", %{"name" => name}, socket) do
    {:noreply, put_tags(socket, List.delete(socket.assigns.tags, name))}
  end

  # A comma finishes a tag, the way the shared pill box does it on every other
  # form: the badge appears as the comma is typed and whatever follows stays in
  # the field. Without this the field keeps "Hund," as text and nothing happens
  # until a button is pressed, which is exactly what it looks like when a field
  # is broken.
  defp absorb_finished_tags(socket) do
    case String.split(socket.assigns.fields["typed"] || "", ",") do
      [_nothing_finished] ->
        socket

      parts ->
        {finished, [rest]} = Enum.split(parts, -1)

        absorb(socket, Enum.join(finished, ","), String.trim_leading(rest))
    end
  end

  # What both ways of finishing a tag do: the names join the chips, and what is
  # left over stays in the field.
  defp absorb(socket, finished, rest) do
    socket
    |> put_tags(socket.assigns.tags ++ Tags.parse_tag_names(finished))
    |> assign(:fields, Map.put(socket.assigns.fields, "typed", rest))
  end

  defp merge_fields(socket, %{"step" => params}) when is_map(params) do
    fields =
      Enum.reduce(params, socket.assigns.fields, fn {key, value}, acc ->
        case Map.fetch(acc, key) do
          {:ok, current} when is_boolean(current) -> Map.put(acc, key, checked?(value))
          {:ok, _current} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    # A checkbox that is unticked posts nothing at all, so a `phx-change` over a
    # step holding checkboxes has to read the absent ones as false rather than
    # leave them at their previous value — otherwise unticking never arrives.
    fields =
      Enum.reduce(step_booleans(socket.assigns.step), fields, fn key, acc ->
        if Map.has_key?(params, key), do: acc, else: Map.put(acc, key, false)
      end)

    assign(socket, :fields, fields)
  end

  defp merge_fields(socket, _params), do: socket

  defp checked?(value), do: value in [true, "true", "1", "on"]

  # Which checkboxes the given step renders. Only a step that actually shows
  # them may read an absent key as "unticked": `handle_event("next", …)` on
  # step 1 carries no settings at all, and treating that as five unticked boxes
  # would silently clear them.
  defp step_booleans(2),
    do: for({key, value} <- default_fields(), is_boolean(value), do: key)

  defp step_booleans(_step), do: []

  defp put_tags(socket, names) do
    # Every entry point that takes a batch owes `canonical_tag_names/1`: it
    # folds two spellings of one topic into the one the profile will carry, so
    # the chips, their counts and the three-tag rule all count topics. A
    # downcase dedupe counted spellings, and showed two chips where the rule
    # under them saw one ("ROR, Ruby on Rails").
    tags =
      names
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Tags.canonical_tag_names()

    # No cap here: the changeset refuses an overlong list with a sentence, and
    # `validate_maximum_tags/2` says why — "rejecting the excess here keeps the
    # form honest instead of silently dropping tags". Taking the first fifteen
    # is that silent drop, and it also hid the refusal from the rule below.
    socket
    |> assign(:tags, tags)
    |> assign(:tag_counts, Map.new(Tags.member_counts_by_name(tags)))
    |> assign(:tag_errors, tag_errors(tags))
  end

  defp advance(socket) do
    step = socket.assigns.step + 1

    socket
    |> assign(:step, step)
    |> assign(:errors, [])
    |> load_suggestions(step)
  end

  # Loaded once, on first arrival at the topics step. Doing it in `mount/3`
  # would spend the query on every visitor who never gets that far, crawlers
  # included.
  defp load_suggestions(socket, 3) do
    case socket.assigns.suggestions do
      [] ->
        suggestions =
          @suggestion_limit
          |> Tags.popular_member_tags()
          |> Enum.map(fn {tag, count} -> {tag.name, count} end)

        assign(socket, :suggestions, suggestions)

      _already ->
        socket
    end
  end

  defp load_suggestions(socket, _step), do: socket

  # Each step is validated with the real changeset of the thing it writes, so
  # the rules never drift from the ones the final POST applies. Deliberately NOT
  # checked here: whether the address is already taken. That answer belongs to
  # the submit, which says nothing and mails the owner instead — asking it in a
  # socket would turn the form into an enumeration oracle.
  #
  # Errors are kept as `{field, message}` rather than a flat list of sentences,
  # because the banner promises "the fields marked in red" and a form that
  # cannot say WHICH field is not keeping that promise.
  defp validate_step(1, fields) do
    user_errors =
      %User{}
      |> User.changeset(%{
        "first_name" => fields["first_name"],
        "last_name" => fields["last_name"]
      })
      |> errors_of([:first_name, :last_name])

    email_errors =
      %Email{}
      |> Email.changeset(%{"value" => fields["email"], "email_type" => "Personal"})
      |> errors_of([:value])
      # The address's own field is called `value` on `Email` and `email` on this
      # form; renaming it here keeps the marking in one vocabulary.
      |> Enum.map(fn {_field, message} -> {:email, message} end)

    user_errors ++ email_errors
  end

  defp validate_step(2, fields) do
    %User{}
    |> User.changeset(%{"gender" => fields["gender"]})
    |> errors_of([:gender])
  end

  defp validate_step(_step, _fields), do: []

  defp errors_of(changeset, fields) do
    for {field, {message, opts}} <- changeset.errors,
        field in fields,
        do: {field, ErrorHelpers.translate_error({message, opts})}
  end

  # The tag rules belong to the registration changeset, which is what the submit
  # runs; asking it here keeps the button's reason and the server's reason the
  # same sentence.
  defp tag_errors(tags) do
    %User{}
    |> User.registration_changeset(%{"tag_list" => Enum.join(tags, ", ")})
    |> errors_of([:tag_list])
  end

  defp failed?(errors, field), do: Enum.any?(errors, &(elem(&1, 0) == field))

  # One sentence per reason, however many fields carry it: the name rule hangs
  # its message on `first_name`, `last_name` AND `nickname`, which under a field
  # each read correctly and in one banner said the same thing three times.
  defp messages(errors), do: errors |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @impl true
  def render(assigns) do
    ~H"""
    <div id="registration-wizard">
      <.step_bar step={@step} />

      <form
        id="registration-form"
        action={~p"/new_registration"}
        method="post"
        phx-change="validate"
        class="mt-5"
      >
        <input type="hidden" name="_csrf_token" value={@csrf_token} />

        <%!-- Filled by app.js on page load, kept by `phx-update="ignore"`; the
              moduledoc says why it is rendered from step 1 rather than beside
              the submit button. --%>
        <input
          type="hidden"
          id="signup-time-zone"
          name="user[time_zone]"
          data-timezone-field
          phx-update="ignore"
        />

        <input type="hidden" name="user[first_name]" value={@fields["first_name"]} />
        <input type="hidden" name="user[last_name]" value={@fields["last_name"]} />
        <input type="hidden" name="user[gender]" value={@fields["gender"]} />
        <input type="hidden" name="user[emails][0][value]" value={@fields["email"]} />
        <input type="hidden" name="user[emails][0][email_type]" value="Personal" />
        <input
          type="hidden"
          name="user[emails][0][public?]"
          value={to_string(@fields["email_public"])}
        />
        <%!-- The two inverted ones: the box reads positively ("allow"), the
              column is negative, so a ticked box posts "false". --%>
        <input
          type="hidden"
          name="user[noindex?]"
          value={to_string(not @fields["search_engines"])}
        />
        <input type="hidden" name="user[noai?]" value={to_string(not @fields["ai_agents"])} />
        <input
          :if={Fediverse.enabled?()}
          type="hidden"
          name="user[fediverse_followers?]"
          value={to_string(@fields["fediverse"])}
        />
        <%!-- Unticked posts "false", which `Prefs.drop_unchosen_booleans/1`
              drops from the params, leaving the column NULL so the member keeps
              inheriting this installation's default. --%>
        <input
          type="hidden"
          name="user[low_bandwidth?]"
          value={to_string(@fields["low_bandwidth"])}
        />
        <input type="hidden" name="user[tag_list]" value={Enum.join(@tags, ", ")} />

        <.error_list errors={@errors} />

        <.step_one
          :if={@step == 1}
          fields={@fields}
          errors={@errors}
        />
        <.step_two
          :if={@step == 2}
          fields={@fields}
        />
        <.step_three
          :if={@step == 3}
          tags={@tags}
          tag_counts={@tag_counts}
          suggestions={@suggestions}
          tag_errors={@tag_errors}
          typed={@fields["typed"]}
        />

        <div class="mt-6 space-y-3">
          <.button :if={@step < 3} type="button" phx-click="next" class="w-full">
            {gettext("Continue")}
          </.button>
          <.button :if={@step == 3} type="submit" class="w-full" disabled={@tag_errors != []}>
            {gettext("Sign up for a free account")}
          </.button>

          <p :if={@step > 1} class="text-center text-sm">
            <button
              type="button"
              phx-click="back"
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Back")}
            </button>
          </p>
        </div>

        <.legal_note :if={@step == 1} />
      </form>
    </div>
    """
  end

  # Three segments, the passed and current ones filled. A progress bar rather
  # than "Schritt 1 von 3" in words: it says the same thing in one glance and
  # survives translation without a placeholder.
  attr(:step, :integer, required: true)

  defp step_bar(assigns) do
    ~H"""
    <div
      class="flex gap-1.5"
      role="progressbar"
      aria-valuemin="1"
      aria-valuemax="3"
      aria-valuenow={@step}
      aria-label={gettext("Sign-up progress")}
    >
      <div
        :for={index <- 1..3}
        class={[
          "h-1 flex-grow rounded-full",
          index <= @step && "bg-brand-600 dark:bg-brand-400",
          index > @step && "bg-slate-200 dark:bg-slate-700"
        ]}
      >
      </div>
    </div>
    """
  end

  attr(:errors, :list, required: true)

  # `<.error_banner>` is the app's one refused-form strip, warning triangle and
  # all, so sign-up's does not become a second look for the same thing — and a
  # failure keeps being signalled by more than colour.
  defp error_list(assigns) do
    ~H"""
    <.error_banner :if={@errors != []} id="registration-errors" class="mt-0 mb-4">
      {Enum.join(banner_sentences(@errors), " ")}
    </.error_banner>
    """
  end

  # The app's sentence for a refused form whenever a field really is marked,
  # then the reasons. A message that belongs to no field (a rejected submit
  # hands those back) stands alone, since "marked in red" would then be a
  # promise nothing keeps.
  defp banner_sentences(errors) do
    marked? = Enum.any?(errors, &(elem(&1, 0) != :base))
    lead = if marked?, do: [gettext("Please check the fields marked in red.")], else: []

    lead ++ messages(errors)
  end

  attr(:fields, :map, required: true)
  attr(:errors, :list, required: true)

  defp step_one(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h2 class="text-xl font-bold text-slate-900 dark:text-white">
          {gettext("Create your free account")}
        </h2>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          <%!-- Not "three answers and you are done": two more steps follow,
                and a promise the next screen breaks is worse than no promise.
                What the first screen can say is the price and roughly what it
                costs in time — a minute is an estimate anybody reads as one,
                where a step count would have been checkable and wrong. --%>
          {gettext("Your free account, in 60 seconds.")}
        </p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div>
          <label for="step_first_name" class="mb-1.5 block text-sm font-semibold text-slate-700 dark:text-slate-300">{gettext("First name")}</label>
          <input
            type="text"
            id="step_first_name"
            name="step[first_name]"
            value={@fields["first_name"]}
            class={input_class(failed?(@errors, :first_name))}
            autocomplete="given-name"
            aria-invalid={failed?(@errors, :first_name) && "true"}
            phx-debounce="blur"
          />
        </div>
        <div>
          <label for="step_last_name" class="mb-1.5 block text-sm font-semibold text-slate-700 dark:text-slate-300">{gettext("Last name")}</label>
          <input
            type="text"
            id="step_last_name"
            name="step[last_name]"
            value={@fields["last_name"]}
            class={input_class(failed?(@errors, :last_name))}
            autocomplete="family-name"
            aria-invalid={failed?(@errors, :last_name) && "true"}
            phx-debounce="blur"
          />
        </div>
      </div>

      <div>
        <label for="step_email" class="mb-1.5 block text-sm font-semibold text-slate-700 dark:text-slate-300">{gettext("Email address")}</label>
        <input
          type="email"
          id="step_email"
          name="step[email]"
          value={@fields["email"]}
          class={input_class(failed?(@errors, :email))}
          autocomplete="email"
          aria-invalid={failed?(@errors, :email) && "true"}
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          phx-debounce="blur"
        />
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext("No password. We send you a PIN by email.")}
        </p>
      </div>
    </div>
    """
  end

  attr(:fields, :map, required: true)

  defp step_two(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h2 class="text-xl font-bold text-slate-900 dark:text-white">
          {gettext("A few settings")}
        </h2>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          <%!-- Named, not linked: nobody here has an account yet, so the
                link would lead to a login wall. The address comes from the
                endpoint, so another installation reads its own.

                No full stop after it, deliberately: a sentence ending on a URL
                hands the reader a period they cannot tell from the address
                (Stefan, 2026-09-19). Grammar loses to the thing people have to
                be able to copy. --%>
          {gettext("Everything can be changed later at %{url}", url: url(~p"/settings"))}
        </p>
      </div>

      <fieldset id="signup-gender">
        <legend class="mb-1.5 block text-sm font-semibold text-slate-700 dark:text-slate-300">
          {gettext("Gender")}
          <span class="font-normal text-slate-600 dark:text-slate-400">{gettext("(optional)")}</span>
        </legend>
        <div class="flex flex-wrap gap-x-5 gap-y-2">
          <label :for={{label, value} <- gender_options()} class={radio_label_class()}>
            <input
              type="radio"
              name="step[gender]"
              value={value}
              checked={@fields["gender"] == value}
              class={radio_class()}
            />
            <span>{label}</span>
          </label>
        </div>
      </fieldset>

      <fieldset id="signup-settings">
        <%!-- No "can be changed at any time" line here: the sentence under
              the step's own heading already says it, with the address. --%>
        <legend class="mb-1.5 block text-sm font-semibold text-slate-700 dark:text-slate-300">{gettext("Settings")}</legend>
        <div class="mt-3 space-y-3">
          <label class="flex items-start gap-2 text-sm text-slate-600 dark:text-slate-300">
            <input
              type="checkbox"
              name="step[email_public]"
              checked={@fields["email_public"]}
              class={checkbox_class()}
            />
            <%!-- The address itself, because "your email address" is the one
                  box here whose consequence a member cannot picture without
                  seeing WHICH address it means — they typed it one screen ago
                  and may well have two. Split on a marker rather than
                  interpolated, so the address can be set in bold where the
                  sentence puts it, in either language. It falls back to the
                  plain wording if the field is somehow empty, which step 1's
                  validation should already have prevented. --%>
            <span :if={@fields["email"] in [nil, ""]}>
              {gettext("Allow others to view your email address")}
            </span>
            <span :if={@fields["email"] not in [nil, ""]}>
              <% {pre, post} =
                split_marker(
                  gettext("The email address {email} is visible on my profile."),
                  "{email}"
                ) %>
              {pre}<strong class="font-semibold">{@fields["email"]}</strong>{post}
            </span>
          </label>
          <label class="flex items-start gap-2 text-sm text-slate-600 dark:text-slate-300">
            <input
              type="checkbox"
              name="step[search_engines]"
              checked={@fields["search_engines"]}
              class={checkbox_class()}
            />
            <span>{gettext("Allow search engines to index your profile")} (SEO)</span>
          </label>
          <label class="flex items-start gap-2 text-sm text-slate-600 dark:text-slate-300">
            <input
              type="checkbox"
              name="step[ai_agents]"
              checked={@fields["ai_agents"]}
              class={checkbox_class()}
            />
            <span>{gettext("Allow AI agents and LLMs to use your profile")} (GEO)</span>
          </label>
          <label :if={Fediverse.enabled?()} class="flex items-start gap-2 text-sm text-slate-600 dark:text-slate-300">
            <input
              type="checkbox"
              name="step[fediverse]"
              checked={@fields["fediverse"]}
              class={checkbox_class()}
            />
            <span>
              {gettext("Take part in the Fediverse")}
              <% {mastodon_pre, mastodon_post} =
                split_marker(
                  gettext("Your public posts then also appear on {mastodon}, for example."),
                  "{mastodon}"
                ) %>
              <span class="mt-0.5 block text-xs font-normal text-slate-600 dark:text-slate-400">
                {mastodon_pre}<a
                  href="https://joinmastodon.org"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >Mastodon</a>{mastodon_post}
              </span>
            </span>
          </label>
          <label class="flex items-start gap-2 text-sm text-slate-600 dark:text-slate-300">
            <input
              type="checkbox"
              name="step[low_bandwidth]"
              checked={@fields["low_bandwidth"]}
              class={checkbox_class()}
            />
            <span>
              {Prefs.label(:low_bandwidth?)}
              <span class="mt-0.5 block text-xs font-normal text-slate-600 dark:text-slate-400">{Prefs.hint(:low_bandwidth?)}</span>
            </span>
          </label>
        </div>
      </fieldset>
    </div>
    """
  end

  attr(:tags, :list, required: true)
  attr(:tag_counts, :map, required: true)
  attr(:suggestions, :list, required: true)
  attr(:tag_errors, :list, required: true)
  attr(:typed, :string, required: true)

  defp step_three(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <%!-- No subtitle: how many are still missing is what the red line under
              the field says, and saying it twice on one short screen is worse
              than saying it once. --%>
        <h2 class="text-xl font-bold text-slate-900 dark:text-white">
          {gettext("What are you interested in?")}
        </h2>
      </div>

      <div>
        <%!-- The box names itself, and the examples in it say what a tag is
              here far faster than a definition would: a language, a hobby, an
              animal. A second visible "Your tags" above the box would say it
              twice on a screen whose heading already asks the question, so the
              label stays for a screen reader only — a placeholder is not one. --%>
        <label for="signup-topic" class="sr-only">{gettext("Your tags")}</label>
        <%!-- No button beside it: the comma in the placeholder and the line
              below name the way in, and the shared pill box has none anywhere
              else on the site either. --%>
        <div class={@tag_errors != [] && "tag-input--error"}>
          <div class="tag-input__box">
            <span :for={name <- @tags} class="tag-input__pill">
              <span class="tag-input__name">{name}</span>
              <span
                :if={count_of(@tag_counts, name) > 0}
                class="rounded-full bg-brand-100 px-1.5 text-xs font-semibold tabular-nums text-brand-700 dark:bg-brand-800 dark:text-brand-100"
              >
                {compact_count(count_of(@tag_counts, name))}
              </span>
              <button
                type="button"
                class="tag-input__remove"
                phx-click="remove_tag"
                phx-value-name={name}
              >
                <span aria-hidden="true">&times;</span>
                <span class="sr-only">{gettext("Remove the tag %{name}", name: name)}</span>
              </button>
            </span>
            <input
              type="text"
              id="signup-topic"
              phx-hook="TagComma"
              name="step[typed]"
              value={@typed}
              class="tag-input__entry"
              autocomplete="off"
              phx-debounce="300"
              aria-invalid={@tag_errors != [] && "true"}
              placeholder={tag_placeholder(@tags)}
              phx-keydown="add_typed"
              phx-key="Enter"
            />
          </div>
        </div>
        <p :if={@tag_errors != []} class="mt-1 text-sm text-rose-700 dark:text-rose-300">
          {Enum.join(messages(@tag_errors), " ")}
        </p>
        <%!-- Shown beside the error rather than instead of it: the red line says
              how many are still missing, this says how to type them, and the
              two are different questions. --%>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext(
            "Separate tags with a comma. A tag may be several words long, like Ruby on Rails."
          )}
        </p>
      </div>

      <div :if={@suggestions != []}>
        <p class="mb-2 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Often chosen:")}
        </p>
        <div class="flex flex-wrap gap-1.5">
          <button
            :for={{name, count} <- @suggestions}
            :if={not chosen?(@tags, name)}
            type="button"
            phx-click="add_tag"
            phx-value-name={name}
            class="inline-flex min-h-10 items-center gap-1.5 rounded-full border border-slate-300 bg-white px-3 text-sm text-slate-700 hover:border-brand-600 hover:text-brand-700 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-300 dark:hover:border-brand-400 dark:hover:text-brand-300"
          >
            {name}
            <span class="rounded-full bg-slate-100 px-1.5 py-0.5 text-xs font-semibold tabular-nums text-slate-600 dark:bg-slate-800 dark:text-slate-300">
              {compact_count(count)}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp legal_note(assigns) do
    ~H"""
    <div class="mt-5 space-y-3">
      <% {nb_pre, nb_rest} =
        split_marker(
          gettext(
            "By creating an account you accept our {nutzungsbedingungen} and confirm that you have read our {datenschutz}."
          ),
          "{nutzungsbedingungen}"
        ) %>
      <% {ds_mid, ds_post} = split_marker(nb_rest, "{datenschutz}") %>
      <p class="text-center text-xs text-slate-600 dark:text-slate-400">
        {nb_pre}<a
          href={~p"/nutzungsbedingungen"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >{gettext("Nutzungsbedingungen")}</a>{ds_mid}<a
          href={~p"/datenschutzerklaerung"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >{gettext("Datenschutzerklärung")}</a>{ds_post}
      </p>

      <p class="text-center text-sm">
        <a
          href={~p"/login"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Already a member? Sign in here.")}
        </a>
      </p>
    </div>
    """
  end

  # The examples are what the empty box is for — they say what counts as a tag
  # here (a language, a hobby, an animal) faster than any definition. Beside a
  # pill they are noise: the line is clipped by the box edge and offers examples
  # the member has already answered, so a short reminder takes over.
  defp tag_placeholder([]),
    do: gettext("Your tags (e.g. JavaScript, Cooking, Origami, Cat)")

  defp tag_placeholder(_tags), do: gettext("Type a tag, then Enter")

  defp count_of(counts, name), do: Map.get(counts, name, 0)

  defp chosen?(tags, name), do: Enum.any?(tags, &(String.downcase(&1) == String.downcase(name)))
end
