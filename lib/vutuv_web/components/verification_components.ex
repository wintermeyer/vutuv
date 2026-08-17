defmodule VutuvWeb.VerificationComponents do
  @moduledoc """
  What a web-proof check actually saw (issue #1466), shared by the two things
  that run one: an organization proving a domain
  (`Vutuv.Organizations.check_domain/2`) and a member proving a profile link is
  their own webpage (`Vutuv.Profiles.LinkVerification.check/3`).

  It is one component because it is one question. A failed check used to answer
  with a single sentence — "not found yet, please try again" — which leaves the
  member re-reading their own zone file or page source with nothing to compare
  against, and on the organization page, where the sentence was an
  auto-dismissing toast, a second attempt with the identical message produced no
  DOM diff at all, so from the second click on the button looked broken. This
  block stays on the page until the next attempt replaces it, and it names the
  value we wanted, where we looked and what was there instead, which is usually
  the whole diagnosis: a record on the wrong name, a stray quote, a rel=me
  link pointing at a different profile, a zone that is not the live one.

  Slate rather than red or amber: a proof that has not propagated yet is the
  ordinary case, not a mistake the member made, and amber belongs to moderation.

  Not globally imported — `import VutuvWeb.VerificationComponents` at the call
  site.
  """

  use Phoenix.Component

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [local_time: 1]

  @doc """
  Stamps the moment a check ran onto its report, so the panel can say when it
  last looked.

  The domain's own `last_checked_at` is a different clock — it belongs to the
  background sweeper's schedule — and a link's is not written by a hand check at
  all, so the answer on screen carries its own.
  """
  def stamp(report) when is_map(report) do
    Map.put(report, :checked_at, NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second))
  end

  attr(:report, :map, default: nil)
  attr(:id, :string, required: true)

  attr(:disabled_text, :string,
    required: true,
    doc: "what to say when verification is off on this installation"
  )

  @doc """
  Renders one check report. Renders nothing without one.

  `checked_at` is optional: a LiveView panel that replaces the report in place
  needs the time to show that anything happened at all, while a page that was
  just reloaded to show it does not.
  """
  def check_report(assigns) do
    ~H"""
    <div
      :if={@report}
      id={@id}
      data-check-report
      role="status"
      class="mt-3 rounded-lg bg-white p-4 text-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700"
    >
      <p class="font-semibold text-slate-900 dark:text-slate-100">
        {gettext("Not found yet")}
        <span :if={@report[:checked_at]}>
          &middot; <.local_time at={@report.checked_at} id={"#{@id}-time"} style={:time} />
        </span>
      </p>

      <%= cond do %>
        <% @report[:disabled?] -> %>
          <p class="mt-2 text-slate-700 dark:text-slate-300">{@disabled_text}</p>
        <% @report.method == "dns" -> %>
          <p class="mt-2 text-slate-700 dark:text-slate-300">
            {gettext("We asked the name servers of your domain directly, for %{names}, and looked for this value:", names: Enum.join(@report.names, ", "))}
          </p>
          <code phx-no-curly-interpolation class={code_class()}><%= @report.expected %></code>
          <p class="mt-3 text-slate-700 dark:text-slate-300">
            {gettext("What is published there right now:")}
          </p>
          <ul :if={@report.found != []} data-check-found class="mt-1 space-y-1">
            <li :for={record <- @report.found}>
              <code phx-no-curly-interpolation class={code_class()}><%= record %></code>
            </li>
          </ul>
          <p
            :if={@report.found == []}
            data-check-found
            class="mt-1 text-slate-600 dark:text-slate-400"
          >
            {gettext("No TXT record at all.")}
          </p>
        <% @report.method == "rel_me" -> %>
          <p class="mt-2 text-slate-700 dark:text-slate-300">
            {gettext("We fetched your page and looked for a link back to:")}
          </p>
          <code phx-no-curly-interpolation class={code_class()}><%= Enum.join(@report.expected, " ") %></code>
          <p class="mt-3 text-slate-700 dark:text-slate-300" data-check-found>
            {rel_me_outcome(@report)}
          </p>
          <ul :if={@report.found != []} class="mt-1 space-y-1">
            <li :for={href <- @report.found}>
              <code phx-no-curly-interpolation class={code_class()}><%= href %></code>
            </li>
          </ul>
        <% true -> %>
          <p class="mt-2 text-slate-700 dark:text-slate-300">{gettext("We fetched this address:")}</p>
          <code phx-no-curly-interpolation class={code_class()}><%= @report.url %></code>
          <p class="mt-3 text-slate-700 dark:text-slate-300" data-check-found>
            {well_known_outcome(@report)}
          </p>
      <% end %>
    </div>
    """
  end

  defp code_class do
    "mt-1 block overflow-x-auto rounded bg-slate-50 px-3 py-2 font-mono text-xs text-slate-900 dark:bg-slate-800 dark:text-slate-100"
  end

  # The one sentence saying what came back from the file fetch. `status: nil`
  # means there was no response at all, which is a different problem from a 404
  # and has to read as one.
  defp well_known_outcome(%{status: nil}),
    do: gettext("We could not reach that address at all.")

  defp well_known_outcome(%{status: 200, found: found}) when is_binary(found) and found != "",
    do: gettext("It answered, but with something else: %{found}", found: found)

  defp well_known_outcome(%{status: 200}),
    do: gettext("It answered with an empty file.")

  defp well_known_outcome(%{status: status}),
    do: gettext("It answered with HTTP status %{status}.", status: status)

  # The same three cases for the back-link method, plus the one that is special
  # to it: the page answered and carries rel=me links, just not this one. Naming
  # them is the diagnosis — a page usually already points at a GitHub or Mastodon
  # profile, and seeing that list beside the wanted address is what tells the
  # member their markup works and only the address is wrong.
  defp rel_me_outcome(%{status: nil}),
    do: gettext("We could not reach your page at all.")

  defp rel_me_outcome(%{status: 200, found: []}),
    do: gettext("Your page has no rel=\"me\" link at all yet.")

  defp rel_me_outcome(%{status: 200}),
    do: gettext("Your page does link back, but somewhere else:")

  defp rel_me_outcome(%{status: status}),
    do: gettext("Your page answered with HTTP status %{status}.", status: status)
end
