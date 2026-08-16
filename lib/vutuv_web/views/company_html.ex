defmodule VutuvWeb.CompanyHTML do
  @moduledoc """
  The two company pages: `/system/investors` and `/system/media-kit`.

  Both are **English only** in every locale (see `VutuvWeb.CompanyController`),
  so nothing here goes through `gettext` — a half-translated page reads worse
  than an honestly monolingual one, and the footer labels them in English to
  say so before the click.
  """
  use VutuvWeb, :html

  alias VutuvWeb.UI

  embed_templates("../templates/company/*")

  @doc """
  A grouped count in **English**, whatever locale the request carries.

  Both company pages are English only, and `delimited_count/1` follows the
  active Gettext locale — so a German visitor was shown "5.934" inside an
  English sentence, which to an English reader is not a tidiness problem but a
  different number. The chrome around the page stays in the reader's language;
  only the figures inside the English text are pinned.
  """
  def en_count(n) when is_integer(n) do
    Gettext.with_locale(VutuvWeb.Gettext, "en", fn -> UI.delimited_count(n) end)
  end

  @doc """
  One of the investor page's figure tiles. Kept beside `en_count/1` rather than
  in the template so every figure on the page is grouped the same way.
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, default: nil)

  def figure_tile(assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 p-4 dark:bg-slate-800/60">
      <p class="text-2xl font-bold text-slate-900 dark:text-white">{@value}</p>
      <p class="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400">
        {@label}
      </p>
      <p :if={@note} class="mt-1 text-xs text-slate-600 dark:text-slate-400">{@note}</p>
    </div>
    """
  end
end
