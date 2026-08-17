defmodule VutuvWeb.ReferenceCheckLive do
  @moduledoc """
  The review panel on one Arbeitszeugnis in the member's editor: the button
  that queues a check, where they stand in the queue while they wait, and the
  result when it arrives.

  Embedded off-router by the `manage` template, so it authenticates the way
  every off-router child here must — `InitAssigns.session_user/1` against the
  cookie's session token, never the curated `session["user_id"]`, which is
  signed but not encrypted and never re-checked against a revoked session.

  A check takes minutes and the queue runs one at a time, so a spinner alone
  would be a lie about what is happening. The panel says which of the three
  real states it is in — waiting behind N others, running, done — and each
  transition arrives over the member's own `Vutuv.Activity` topic rather than
  by polling.

  The finished analysis is **not** rendered here. It runs to ~10_000 characters
  and opens with a five-column matrix, which in this card had 468px to live in
  and could only be read by scrolling sideways, so it has a page of its own
  (`JobReferenceController.show_check/2`) and this panel keeps what a list is
  for: the state, and the way in.
  """

  use VutuvWeb, :live_view

  alias Vutuv.References
  alias Vutuv.References.Check
  alias Vutuv.References.Checks
  alias Vutuv.References.JobReference
  alias Vutuv.Repo
  alias VutuvWeb.Live.InitAssigns

  # The turning hourglass the photo-moderation wait already uses. An hourglass
  # rather than a spinner on purpose, and the reason is the same here: a
  # spinner says "loading", while this is a wait for something being *judged*,
  # over a duration the member cannot shorten. It pauses at each half-turn like
  # a real one and stops entirely under prefers-reduced-motion.
  import VutuvWeb.PostComponents, only: [hourglass: 1]

  # The grade label, shared with the result page so the two cannot state the
  # verdict differently. Its module embeds the templates that render *this*
  # LiveView, but only as an atom argument to `live_render/3` — a runtime
  # reference, not a compile-time one — so the import closes no cycle.
  import VutuvWeb.JobReferenceHTML, only: [grade_label: 1]

  # Two things every off-router `live_render` child here has to do for itself,
  # and both fail silently rather than loudly:
  #
  #   * `layout: false` — `use VutuvWeb, :live_view` carries the `:app` layout,
  #     so an embedded child renders the whole top bar and nav *inside* its
  #     host's card. Caught in the browser; no test would have seen it.
  #   * the session locale — a LiveView mounted outside the `live_session` gets
  #     no `LiveLocale` hook, so every gettext call in it falls back to English
  #     while the page around it is German.
  @impl true
  def mount(_params, session, socket) do
    reference_id = session["job_reference_id"]
    VutuvWeb.LiveLocale.put_viewer(session)
    socket = assign(socket, page_title: nil)

    if connected?(socket) do
      mount_authenticated(reference_id, session, socket)
    else
      # The throwaway dead render. Its own HTTP request was already
      # authenticated; the socket re-checks the token the moment it connects.
      {:ok, assign(socket, reference: nil, check: nil, viewer: nil, ready?: false), layout: false}
    end
  end

  defp mount_authenticated(reference_id, session, socket) do
    case InitAssigns.session_user(session) do
      nil ->
        {:ok, assign(socket, reference: nil, check: nil, viewer: nil, ready?: true),
         layout: false}

      user ->
        Vutuv.Activity.subscribe(user.id)
        # Two subscriptions, because two different things move this panel: the
        # member's own check changing state (their topic), and the queue in
        # front of them shortening as *other* members' checks finish — which
        # never reaches their own topic.
        Checks.subscribe_queue()

        reference = References.get_job_reference(user, reference_id)

        {:ok,
         socket
         |> assign(viewer: user, reference: reference, ready?: true)
         |> put_check(reference && Checks.latest_for(reference)), layout: false}
    end
  end

  @impl true
  def handle_event("check", _params, socket) do
    %{reference: reference} = socket.assigns

    case reference && Checks.enqueue(reference) do
      {:ok, check} ->
        {:noreply, socket |> put_check(check) |> assign(error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reference_check, %Check{} = check}, socket) do
    if socket.assigns.reference && check.job_reference_id == socket.assigns.reference.id do
      # Re-read the entry too: a finished check is judged against the text as
      # it stands now, which is what makes an edited Zeugnis show as outdated.
      reference = Repo.get(JobReference, check.job_reference_id)

      {:noreply,
       socket
       |> assign(reference: reference || socket.assigns.reference)
       |> put_check(check)}
    else
      {:noreply, socket}
    end
  end

  # Somebody else's check left the waiting set, so this one moved up. The check
  # row itself is unchanged — only its place in the queue is — which is exactly
  # why the position is an assign and not computed in the template: a re-render
  # needs something that actually differs.
  def handle_info(:queue_changed, socket) do
    {:noreply, put_check(socket, socket.assigns[:check])}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The position is nil for anything but a waiting check, so a finished panel
  # ignores queue traffic entirely. The wait estimate is computed with it,
  # because it is a function of that position — and it exists only once there
  # IS a check: the state before the button is pressed quotes no duration at
  # all (see `check_state/1`).
  defp put_check(socket, check) do
    assign(socket,
      check: check,
      position: check && Checks.queue_position(check),
      wait: check && format_duration(Checks.estimated_wait_ms(check))
    )
  end

  # Rounded to whole minutes above one, because the honest precision here is
  # low and "about 4 minutes" is what a member can act on. Below a minute it
  # stays in seconds, or a 45-second review would advertise itself as a minute.
  defp format_duration(nil), do: nil

  defp format_duration(ms) when ms < 60_000 do
    seconds = max(div(ms, 1000), 5)
    ngettext("%{count} second", "%{count} seconds", seconds)
  end

  defp format_duration(ms) do
    minutes = max(round(ms / 60_000), 1)
    ngettext("%{count} minute", "%{count} minutes", minutes)
  end

  @impl true
  def render(%{ready?: false} = assigns) do
    ~H"""
    <div class="text-sm text-slate-500 dark:text-slate-400">{gettext("Loading…")}</div>
    """
  end

  def render(%{reference: nil} = assigns) do
    ~H"""
    <div></div>
    """
  end

  def render(assigns) do
    ~H"""
    <%!-- No panel around this. It used to sit in a bordered slate-50 box —
          a box inside the card inside the list, adding an outline but no
          meaning, and its grey swallowed the secondary button (slate-100 on
          slate-50 is not a control, it is a smudge). The grade label brings
          its own tint, which is all the grouping this needs. --%>
    <div>
      <div :if={!Checks.enabled?()} class="text-sm text-slate-600 dark:text-slate-400">
        {gettext("The AI review is not available on this installation.")}
      </div>

      <%!-- Said, not hidden: a missing button reads as a broken feature,
            while the reason is something the member can act on. --%>
      <div
        :if={Checks.enabled?() && !References.check_supported?(@reference)}
        class="text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext(
          "The AI review reads German employment law and is therefore offered for German Arbeitszeugnisse only."
        )}
      </div>

      <div :if={Checks.enabled?() && References.check_supported?(@reference)}>
        <.check_state
          check={@check}
          reference={@reference}
          viewer={@viewer}
          position={assigns[:position]}
          wait={assigns[:wait]}
          error={assigns[:error]}
        />
      </div>
    </div>
    """
  end

  attr(:check, :any, default: nil)
  attr(:reference, :any, required: true)
  # Threaded down to `check_error/1` because one refusal — the used-up
  # allowance — has to say how long is left on *this* member's window. It was
  # missing from both attr lists for a while, and a function component gets
  # exactly the assigns it is passed, so `assigns[:viewer]` was silently nil
  # and every rate-limited member got the vague fallback wording instead of
  # their own wait.
  attr(:viewer, :any, default: nil)
  attr(:position, :any, default: nil)
  attr(:wait, :any, default: nil)
  attr(:error, :any, default: nil)

  defp check_state(%{check: nil} = assigns) do
    ~H"""
    <%!-- What is read and what comes out, before the button rather than after
          it. "Have this reference reviewed" named neither: it left a member
          guessing whether we check spelling, completeness or whether the
          document is genuine — and that last reading is the dangerous one,
          because we never confirm authenticity. What we actually do is decode
          the wording, and what a member actually wants is the grade hiding in
          it, so the copy says both. --%>
    <p class="mb-2 text-sm text-slate-700 dark:text-slate-300">
      {gettext(
        "German references are graded in code, so friendly words can carry a poor mark. We read the wording against German employment-reference law and tell you which grade is in it, what each assessing phrase really says, and what is missing, contradictory or formally wrong."
      )}
    </p>

    <div class="flex flex-wrap items-center gap-3">
      <%!-- The primary-button recipe at a full 40px height: this stands alone
            in a card footer on a phone, not in a dense row. --%>
      <button
        type="button"
        phx-click="check"
        class="min-h-10 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Decode this reference")}
      </button>
      <%!-- No duration here, deliberately. This line used to open with
            "Usually about 4 minutes", worked out from the median of past runs
            and what is queued — a promise made before there is anything to
            hold it to, and one long document or a cold model is enough to
            double it. The wait is quoted once the check is queued, where the
            member is also shown the queue position it is built on. --%>
      <span class="text-xs text-slate-600 dark:text-slate-400">
        {gettext("Only you see the result.")}
      </span>
    </div>
    <.check_error error={@error} viewer={@viewer} />
    """
  end

  defp check_state(%{check: %Check{status: "pending"}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-300" role="status">
      <.hourglass class="mt-0.5 h-5 w-5 shrink-0 text-slate-600 dark:text-slate-400" />
      <div>
        <p class="mb-0">
          <span :if={@position && @position > 0}>
            {ngettext(
              "Waiting — %{count} review ahead of yours.",
              "Waiting — %{count} reviews ahead of yours.",
              @position
            )}
          </span>
          <span :if={@position == 0}>{gettext("Waiting — yours is next.")}</span>
        </p>
        <%!-- The wait, from what this installation's own runs really took,
              rather than a hardcoded "a few minutes" that means 45 seconds on
              a GPU and eleven on a CPU. Rendered only once there is data. --%>
        <p :if={@wait} class="mb-0 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Usually about %{duration}.", duration: @wait)}
        </p>
        <.leave_note />
      </div>
    </div>
    """
  end

  defp check_state(%{check: %Check{status: "running"}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 text-sm text-slate-700 dark:text-slate-300" role="status">
      <.hourglass class="mt-0.5 h-5 w-5 shrink-0 text-brand-600 dark:text-brand-400" />
      <div>
        <p class="mb-0">
          <span :if={@wait}>
            {gettext("Reviewing your reference. This usually takes about %{duration}.",
              duration: @wait
            )}
          </span>
          <span :if={!@wait}>{gettext("Reviewing your reference. This takes a few minutes.")}</span>
        </p>
        <.leave_note />
      </div>
    </div>
    """
  end

  defp check_state(%{check: %Check{status: "done"}} = assigns) do
    assigns = assign(assigns, current?: Check.current_for?(assigns.check, assigns.reference))

    ~H"""
    <%!-- The verdict leads, the way in follows. A member with several
          Zeugnissen scans this column for the grade, not for a row of
          identical buttons, so the tinted label is the first thing in the
          panel and the control below it is deliberately the calm secondary
          recipe: the loud primary belongs to the review they have NOT run
          yet, not to one they can re-read. --%>
    <.grade_label check={@check} class="mb-2" />

    <div class="flex flex-wrap items-center gap-3">
      <%!-- The result lives on its own page. It runs to ~10_000 characters and
            opens with a five-column matrix, which in this card had 468px to
            live in — readable only by scrolling it sideways. Here the panel
            keeps what the list is for: the state, and the way in. --%>
      <.link
        navigate={~p"/settings/job_references/#{@reference}/check"}
        class="min-h-10 inline-flex items-center rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        {gettext("Read the review")}
      </.link>
    </div>

    <%!-- A warning with no way out is just bad news. The text really did
          change, so the answer to it is another review — offered here rather
          than making the member find the button again two rows up. --%>
    <div :if={!@current?} class="mt-3 flex flex-wrap items-center gap-3">
      <p class="text-xs text-amber-700 dark:text-amber-300">
        {gettext("You changed the text after this review.")}
      </p>
      <button
        type="button"
        phx-click="check"
        class="min-h-10 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Review again")}
      </button>
    </div>
    <.check_error error={@error} viewer={@viewer} />
    """
  end

  defp check_state(%{check: %Check{status: "failed"}} = assigns) do
    ~H"""
    <div>
      <p class="text-sm text-slate-700 dark:text-slate-300">
        {gettext("The review could not be completed.")}
      </p>
      <button
        type="button"
        phx-click="check"
        class="mt-2 text-xs text-slate-600 underline dark:text-slate-400"
      >
        {gettext("Try again")}
      </button>
      <.check_error error={@error} viewer={@viewer} />
    </div>
    """
  end

  defp check_state(assigns) do
    ~H"""
    <div></div>
    """
  end

  # The permission to walk away, said on both waiting states. A wait measured
  # in minutes — and in a busy queue, in somebody else's minutes — is a wait
  # nobody should be asked to sit through, and a page that does not say so
  # keeps people watching an hourglass. It is only honest because the result
  # really does find them afterwards: a notification, and an email for the
  # member who logged out (`Vutuv.Activity.notify_reference_check/2`).
  defp leave_note(assigns) do
    ~H"""
    <p class="mb-0 mt-1 text-xs text-slate-600 dark:text-slate-400">
      {gettext(
        "You can leave this page. The result lands in your notifications, and we email it to you if you are no longer here by then."
      )}
    </p>
    """
  end

  attr(:error, :any, default: nil)
  attr(:viewer, :any, default: nil)

  defp check_error(%{error: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  defp check_error(assigns) do
    ~H"""
    <p class="mt-2 text-xs text-rose-700 dark:text-rose-300">
      {error_message(@error, assigns[:viewer])}
    </p>
    """
  end

  # The one message that needs to know *whose* allowance ran out, because it
  # says how long is left on it.
  defp error_message(:rate_limited, viewer),
    do: VutuvWeb.JobReferenceHTML.rate_limit_message(viewer && viewer.id)

  defp error_message(other, _viewer), do: error_message(other)

  defp error_message(:already_queued),
    do: gettext("A review for this reference is already running.")

  defp error_message(:no_body),
    do: gettext("There is no text to review yet. Upload the document or paste the text.")

  defp error_message(:unsupported_country),
    do: gettext("The review covers German Arbeitszeugnisse only.")

  defp error_message(_other), do: gettext("The review could not be started.")
end
