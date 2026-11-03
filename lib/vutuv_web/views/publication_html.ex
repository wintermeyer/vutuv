defmodule VutuvWeb.PublicationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.BerlinTime
  alias VutuvWeb.WorkExperienceHTML

  embed_templates("../templates/publication/*")

  @doc "The `{name, number}` month options, shared with the work-experience form."
  defdelegate month_options, to: WorkExperienceHTML

  @doc """
  The years the publication form offers, newest first. One year ahead of
  today, because "in press" for next year's volume is how a paper is dated
  before it appears.
  """
  def year_options, do: (BerlinTime.today().year + 1)..1900//-1

  @doc """
  The meta line under a title: the co-authors, where it appeared, and when,
  joined with middots. Any part that is blank drops out, so a bare-title
  entry renders no orphan separators.
  """
  def meta_line(publication) do
    [publication.authors, publication.publisher, published_text(publication)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc ~S(The publication date as `2018` or `3/2018`, nil when the member gave none.)
  def published_text(%{published_year: nil}), do: nil
  def published_text(%{published_year: year, published_month: nil}), do: Integer.to_string(year)
  def published_text(%{published_year: year, published_month: month}), do: "#{month}/#{year}"

  @doc """
  The neutral "document" glyph shown beside each entry (the Heroicons outline
  "document-text" icon, inlined). Shared by the section list and the profile's
  Publications card, so both read the same.
  """
  attr(:class, :string, default: "h-5 w-5")

  def publication_glyph(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"
      />
    </svg>
    """
  end

  @doc """
  One list row: the glyph, the title (linking to its entry page), the meta
  line, the description and the outbound link. Shared by the public section
  page and the owner's editor; the profile card renders its own compact rows.
  """
  attr(:user, :any, required: true)
  attr(:publication, :any, required: true)

  def publication_row(assigns) do
    assigns = assign(assigns, :meta, meta_line(assigns.publication))

    ~H"""
    <.publication_glyph class="mt-0.5 h-5 w-5 shrink-0 text-slate-400 dark:text-slate-500" />
    <div class="min-w-0 flex-1">
      <.link
        href={~p"/#{@user}/publications/#{@publication}"}
        class="font-medium text-slate-900 hover:text-brand-700 dark:hover:text-brand-300 dark:text-white"
      >
        {@publication.title}
      </.link>
      <p :if={@meta != ""} class="text-sm text-slate-600 dark:text-slate-400">{@meta}</p>
      <.markdown_prose
        :if={@publication.description}
        text={@publication.description}
        class="mt-1 text-sm text-slate-600 dark:text-slate-400"
      />
      <a
        :if={@publication.url}
        href={@publication.url}
        target="_blank"
        rel="nofollow noopener noreferrer"
        class="mt-0.5 inline-flex items-center gap-1 text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Read")}
        <span aria-hidden="true">↗</span>
      </a>
    </div>
    """
  end
end
