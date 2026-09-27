defmodule VutuvWeb.PostFileComponents do
  @moduledoc """
  What a published post shows of its files (issue #2108): per file a strip of
  its first pages as pictures, opening in the shared lightbox, and a chip with
  the name, the size and the page count that hands the file over.

  Every address comes from `Vutuv.Attachments` (`file_url/1`, `page_url/3`),
  and the proxy behind them asks the post's audience again on each request, so
  the card and the bytes cannot disagree about who may have them. The feed
  card and the permalink draw the same markup: a reader deciding whether to
  open a file wants to see what it is in both.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [file_size: 1, lightbox_gallery: 1, delimited_count: 1]

  alias Vutuv.Attachments

  attr(:files, :list, required: true, doc: "the post's shown attachments, `:pages` preloaded")
  attr(:id, :string, required: true, doc: "the card's entry key, for unique DOM ids")
  attr(:permalink, :string, required: true)
  attr(:report?, :boolean, default: false, doc: "whether the viewer may report a file here")

  def post_files(assigns) do
    ~H"""
    <ul class="mt-3 space-y-3" data-post-files>
      <li
        :for={file <- @files}
        id={"#{@id}-file-#{file.id}"}
        data-post-file={file.id}
        class="rounded-2xl p-2 ring-1 ring-slate-200 dark:ring-slate-700"
      >
        <.lightbox_gallery
          :if={file.pages != []}
          class="mb-2 flex gap-2 overflow-x-auto"
        >
          <a
            :for={{page, index} <- Enum.with_index(file.pages)}
            href={Attachments.page_url(file, page, "large")}
            class="shrink-0 cursor-zoom-in"
            data-lightbox-photo={index}
            data-photo-src={Attachments.page_url(file, page, "large")}
            data-photo-alt={page_alt(file, index, length(file.pages))}
            data-photo-download={Attachments.file_url(file)}
            data-photo-position={page_alt(file, index, length(file.pages))}
          >
            <img
              src={Attachments.page_url(file, page, "thumb")}
              alt={page_alt(file, index, length(file.pages))}
              width={page.width}
              height={page.height}
              loading="lazy"
              class="h-40 w-auto rounded-lg bg-white ring-1 ring-slate-200 dark:ring-slate-700"
            />
          </a>
        </.lightbox_gallery>
        <a
          href={Attachments.file_url(file)}
          download={file.file_name}
          class="flex items-center gap-3 rounded-xl px-2 py-2 no-underline! hover:bg-slate-50 dark:hover:bg-slate-800"
          data-post-file-download
        >
          <span class="shrink-0 text-xl" aria-hidden="true">📎</span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-semibold text-slate-900 dark:text-slate-100">
              {file.file_name}
            </span>
            <span class="block text-xs text-slate-500 dark:text-slate-400">
              {file_facts(file)}
            </span>
          </span>
          <span class="shrink-0 text-xs font-medium text-sky-700 dark:text-sky-300">
            {gettext("Download file")}
          </span>
        </a>
        <.link
          :if={@report?}
          id={"#{@id}-file-#{file.id}-report"}
          navigate={
            "/reports/new?" <>
              URI.encode_query(type: "attachment", id: file.id, return_to: @permalink)
          }
          class="ml-2 text-xs text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
        >
          ⚑ {gettext("Report this file")}
        </.link>
      </li>
    </ul>
    """
  end

  # "84 kB · 3 pages", the page count only where the file has pages of its own
  # (a text file's one drawn page is not a page count).
  defp file_facts(%{page_count: count} = file) when is_integer(count) and count > 0 do
    file_size(file.size_bytes) <>
      " · " <>
      ngettext("%{formatted} page", "%{formatted} pages", count,
        formatted: delimited_count(count)
      )
  end

  defp file_facts(file), do: file_size(file.size_bytes)

  defp page_alt(file, index, total) do
    gettext("%{name}, page %{n} of %{total}", name: file.file_name, n: index + 1, total: total)
  end
end
