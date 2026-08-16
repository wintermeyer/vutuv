defmodule VutuvWeb.ImportHTML do
  @moduledoc false
  use VutuvWeb, :html

  @doc """
  The analysis summary above the candidate lists (issue #1477): one row per
  supported section with what the archive held, what is already on the profile
  and what is left to import.

  Counts candidates rather than CSV rows, because a raw row count needs an
  "ignored" column to add up, and the largest ignored group would be the
  entries a real archive simply repeats across its files, which the importer
  collapses on purpose: a number that reads like lost data while describing
  the importer working correctly.

  Mobile-first sizing, measured rather than guessed: the headers **wrap**, and
  they carry no `uppercase tracking-wide` (German labels set in caps cost this
  table ~54px, which is the difference between four columns fitting a phone and
  the "Ready to import" figure sitting off the right edge). At 8px cell padding
  the table's min-content is ~304px against the ~310px a 390px phone leaves
  inside the card. The `overflow-x-auto` wrapper is the backstop for anything
  narrower, and it is what keeps a wide table from scrolling the whole page
  sideways.
  """
  attr(:rows, :list, required: true)

  def analysis_summary(assigns) do
    ~H"""
    <div class="mt-4 overflow-x-auto">
      <table class="w-full text-sm" data-import-summary>
        <thead>
          <tr class="border-b border-slate-200 text-left text-xs font-semibold text-slate-500 dark:border-slate-700 dark:text-slate-400">
            <th scope="col" class="py-2 pr-2">{gettext("Section")}</th>
            <th scope="col" class="px-2 py-2 text-right">{gettext("Found")}</th>
            <th scope="col" class="px-2 py-2 text-right">{gettext("Already on your profile")}</th>
            <th scope="col" class="py-2 pl-2 text-right">{gettext("Ready to import")}</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100 dark:divide-slate-800">
          <tr
            :for={row <- @rows}
            data-import-summary-row={row.key}
            class={
              if(row.found == 0,
                do: "text-slate-500 dark:text-slate-400",
                else: "text-slate-800 dark:text-slate-200"
              )
            }
          >
            <th scope="row" class="py-2 pr-2 text-left font-medium">{section_label(row.key)}</th>
            <td class="px-2 py-2 text-right tabular-nums">{delimited_count(row.found)}</td>
            <td class="px-2 py-2 text-right tabular-nums">{delimited_count(row.present)}</td>
            <td class="py-2 pl-2 text-right font-semibold tabular-nums">
              {delimited_count(row.available)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  The name of an import section, in one place: the summary table above the
  candidate lists and the lists themselves both title themselves from here, so
  they can never name a section differently. That was the claim of the comment
  this replaces, while the template wrote all eight words out a second time.
  """
  def section_label(:positions), do: gettext("Work experience")
  def section_label(:educations), do: gettext("Education")
  def section_label(:certifications), do: gettext("Certificates & licenses")
  def section_label(:skills), do: gettext("Tags")
  def section_label(:urls), do: gettext("Links")
  def section_label(:social), do: gettext("Social media")
  def section_label(:phones), do: gettext("Phone numbers")
  def section_label(:profile), do: gettext("Profile")

  @doc """
  One selectable candidate: a checkbox + label, greyed when it is a duplicate.

  Whether the box arrives ticked is `select?`, decided by
  `Vutuv.Imports.LinkedIn.mark_duplicates/2` — for most sections that is simply
  "not a duplicate", for tags it also honours the profile's free slots. A
  duplicate is marked `data-duplicate` so the client-side cap can ignore it:
  submitting one costs no tag slot, the apply step skips it.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:duplicate?, :boolean, default: false)
  attr(:select?, :boolean, default: true)

  def candidate_row(assigns) do
    ~H"""
    <li class="flex items-start gap-3 py-2">
      <input
        type="checkbox"
        name="selected[]"
        value={@id}
        checked={@select?}
        data-duplicate={@duplicate? && "true"}
        class={checkbox_class()}
        id={"cand-#{@id}"}
      />
      <label
        for={"cand-#{@id}"}
        class={["text-sm", if(@duplicate?, do: "text-slate-500 dark:text-slate-400", else: "text-slate-800 dark:text-slate-200")]}
      >
        {@label}
        <span :if={@duplicate?} class="ml-1 text-xs text-slate-500 dark:text-slate-400">
          ({gettext("already on your profile")})
        </span>
      </label>
    </li>
    """
  end

  @doc """
  A titled group of candidate rows, rendered only when the group is non-empty.

  `limit` caps how many non-duplicate boxes may be ticked at once — only the
  tags pass one (the profile's free slots). It rides the group as
  `data-select-limit`, where both the "select all" toggle and the per-box guard
  in `app.js` read it; with JS off the server's own preselection is already
  within the cap, so nothing here is load-bearing for correctness.
  """
  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:limit, :integer, default: nil)
  slot(:note)
  slot(:inner_block, required: true)

  def candidate_section(assigns) do
    ~H"""
    <div :if={@items != []} class="mt-6" data-select-group data-select-limit={@limit}>
      <.select_group_header title={@title} limit={@limit} />
      {render_slot(@note)}
      <%!-- The client-side cap's refusal line. Turned off by the `hidden`
      attribute and carrying no display utility, so nothing can out-cascade it
      (the issue #880 trap). --%>
      <p
        :if={@limit}
        data-select-notice
        hidden
        role="status"
        class="mt-1 text-xs font-medium text-red-600 dark:text-red-400"
      >
        {gettext("There is no room for more. Uncheck one to pick another.")}
      </p>
      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  The tag section's capacity line: what the member holds now, and how much of
  this import is spoken for.

  Two sentences, and the split matters. The first is about the **profile** and
  never moves. The second is about the **selection** and is live — the client
  cap rewrites it as boxes are ticked — so it counts what is selected rather
  than what is left: a "you can import N more" phrasing reads as `0` the moment
  the page ticks its N preselected boxes, which is the arrival state of every
  import that has room. It carries its whole sentence as `data-label-selected`
  (the `{n}` marker convention `<.pin_time_left>` uses; gettext only
  interpolates `%{…}`, so the markers pass through untouched), so the JS writes
  no translated word of its own.

  A full profile gets the way out instead of a number: the tags editor.
  """
  attr(:used, :integer, required: true)
  attr(:max, :integer, required: true)
  attr(:free, :integer, required: true)

  def tag_capacity_note(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-slate-600 dark:text-slate-400" data-tag-capacity>
      {gettext("You have %{used} of %{max} tags.", used: @used, max: @max)}
      <span :if={@free > 0} data-select-free data-label-selected={selected_label_template()}>
        {selected_label(@free, @free)}
      </span>
      <span :if={@free == 0}>
        {gettext("There is no room for more.")}
        <.link
          navigate={~p"/settings/tags"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Remove tags first")}
        </.link>.
      </span>
    </p>
    """
  end

  @doc """
  The live selection sentence's template, `{n}` of `{max}` still to fill in.
  Shared by the server's first render and the `app.js` rewrite, so the two can
  never word it differently.
  """
  def selected_label_template, do: gettext("{n} of {max} free slots selected.")

  @doc "`selected_label_template/0` with the two figures filled in."
  def selected_label(selected, free) do
    selected_label_template()
    |> String.replace("{n}", Integer.to_string(selected))
    |> String.replace("{max}", Integer.to_string(free))
  end

  @doc """
  Section header for a group of selectable candidates: the title plus a
  "select all / deselect all" toggle. The toggle is a progressive enhancement
  (the `data-select-all` button in `app.js` reveals it and flips every checkbox
  inside the enclosing `[data-select-group]`), so it starts hidden and does
  nothing with JS off. It carries both labels so the JS can swap them without
  hardcoding a translated string.

  A capped group (`limit`, the tags) gets its own select label: it ticks as many
  as fit and stops, so calling that "Select all" would name something the button
  deliberately does not do.
  """
  attr(:title, :string, required: true)
  attr(:limit, :integer, default: nil)

  def select_group_header(assigns) do
    assigns =
      assign(
        assigns,
        :select_label,
        if(assigns.limit, do: gettext("Select as many as fit"), else: gettext("Select all"))
      )

    ~H"""
    <div class="flex items-center justify-between gap-3">
      <.section_title>{@title}</.section_title>
      <button
        type="button"
        data-select-all
        data-label-select={@select_label}
        data-label-deselect={gettext("Unselect all")}
        class="hidden text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {@select_label}
      </button>
    </div>
    """
  end

  embed_templates("../templates/import/*")
end
