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

  # The same words the candidate lists below the table are titled with, so the
  # summary and the lists can never name a section differently.
  defp section_label(:positions), do: gettext("Work experience")
  defp section_label(:educations), do: gettext("Education")
  defp section_label(:certifications), do: gettext("Certificates & licenses")
  defp section_label(:skills), do: gettext("Tags")
  defp section_label(:urls), do: gettext("Links")
  defp section_label(:social), do: gettext("Social media")
  defp section_label(:phones), do: gettext("Phone numbers")
  defp section_label(:profile), do: gettext("Profile")

  @doc "One selectable candidate: a checkbox + label, greyed when it is a duplicate."
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:duplicate?, :boolean, default: false)

  def candidate_row(assigns) do
    ~H"""
    <li class="flex items-start gap-3 py-2">
      <input
        type="checkbox"
        name="selected[]"
        value={@id}
        checked={not @duplicate?}
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

  @doc "A titled group of candidate rows, rendered only when the group is non-empty."
  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  slot(:inner_block, required: true)

  def candidate_section(assigns) do
    ~H"""
    <div :if={@items != []} class="mt-6" data-select-group>
      <.select_group_header title={@title} />
      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  Section header for a group of selectable candidates: the title plus a
  "select all / deselect all" toggle. The toggle is a progressive enhancement
  (the `data-select-all` button in `app.js` reveals it and flips every checkbox
  inside the enclosing `[data-select-group]`), so it starts hidden and does
  nothing with JS off. It carries both labels so the JS can swap them without
  hardcoding a translated string.
  """
  attr(:title, :string, required: true)

  def select_group_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <.section_title>{@title}</.section_title>
      <button
        type="button"
        data-select-all
        data-label-select={gettext("Select all")}
        data-label-deselect={gettext("Unselect all")}
        class="hidden text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Select all")}
      </button>
    </div>
    """
  end

  embed_templates("../templates/import/*")
end
