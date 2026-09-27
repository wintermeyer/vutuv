defmodule VutuvWeb.PostFileComponents do
  @moduledoc """
  What a published post shows of its files (issue #2108): one compact row per
  file, with its first page as a small picture, the name, the size and the page
  count, a "Preview" that opens the rendered pages in the shared lightbox and
  a "Download" that hands the file over.

  The row stays the same height whether the file has one page or a hundred:
  the pages themselves wait in the lightbox, so a long document does not push
  the conversation down the feed. Every address comes from
  `Vutuv.Attachments` (`file_url/1`, `page_url/3`), and the proxy behind them
  asks the post's audience again on each request, so the card and the bytes
  cannot disagree about who may have them.
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
    <ul class="mt-3 space-y-2" data-post-files>
      <li :for={file <- @files} id={"#{@id}-file-#{file.id}"} data-post-file={file.id}>
        <.lightbox_gallery class="flex items-center gap-3.5 rounded-[14px] border border-slate-200 px-3.5 py-2.5 dark:border-slate-700">
          <%!-- The first page, which also opens the preview. The other pages
          ride along as descriptions only, so the lightbox can step through
          them without the row showing them. --%>
          <a
            :if={file.pages != []}
            href={Attachments.page_url(file, hd(file.pages), "large")}
            class="shrink-0 cursor-zoom-in"
            data-lightbox-photo="0"
            data-photo-src={Attachments.page_url(file, hd(file.pages), "large")}
            data-photo-alt={page_alt(file, 0, length(file.pages))}
            data-photo-download={Attachments.file_url(file)}
            data-photo-position={page_alt(file, 0, length(file.pages))}
          >
            <img
              src={Attachments.page_url(file, hd(file.pages), "thumb")}
              alt={page_alt(file, 0, length(file.pages))}
              width="44"
              height="62"
              loading="lazy"
              class="block h-[62px] w-11 max-w-none rounded border border-slate-300 bg-white object-cover object-top dark:border-slate-600"
            />
          </a>
          <span
            :for={{page, index} <- file.pages |> Enum.with_index() |> Enum.drop(1)}
            hidden
            data-photo-src={Attachments.page_url(file, page, "large")}
            data-photo-alt={page_alt(file, index, length(file.pages))}
            data-photo-download={Attachments.file_url(file)}
            data-photo-position={page_alt(file, index, length(file.pages))}
          />
          <span :if={file.pages == []} class="flex h-[62px] w-11 shrink-0 items-center justify-center text-2xl" aria-hidden="true">📎</span>
          <div class="min-w-0 flex-1">
            <div class="truncate text-[15px] font-semibold leading-snug text-slate-900 dark:text-slate-100">
              {file.file_name}
            </div>
            <div class="text-[13px] leading-snug text-slate-500 dark:text-slate-400">
              {file_facts(file)}
            </div>
            <%!-- Each link reaches 40 px of finger through padding it takes
            back with a negative margin, so the row stays as tight as it
            looks while the target does not shrink with it. --%>
            <div class="-mx-[7px] mt-1 flex flex-wrap items-center">
              <%!-- `data-lightbox-photo` without a `data-photo-src`: a control
              that opens the gallery, not another picture in it. --%>
              <a
                :if={file.pages != []}
                href={Attachments.page_url(file, hd(file.pages), "large")}
                data-lightbox-photo="0"
                class="-my-2.5 px-[7px] py-2.5 text-[13px] font-medium text-sky-700 dark:text-sky-300"
              >
                {gettext("Preview")}
              </a>
              <a
                href={Attachments.file_url(file)}
                download={file.file_name}
                class="-my-2.5 px-[7px] py-2.5 text-[13px] font-medium text-sky-700 dark:text-sky-300"
                data-post-file-download
              >
                {pgettext("post file", "Download")}
              </a>
              <.link
                :if={@report?}
                id={"#{@id}-file-#{file.id}-report"}
                navigate={
                  "/reports/new?" <>
                    URI.encode_query(type: "attachment", id: file.id, return_to: @permalink)
                }
                class="-my-2.5 px-[7px] py-2.5 text-xs text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
              >
                {gettext("Report this file")}
              </.link>
            </div>
          </div>
        </.lightbox_gallery>
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
