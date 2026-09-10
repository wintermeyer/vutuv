defmodule VutuvWeb.AttachmentText do
  @moduledoc """
  What a member is told when a file is refused — written once, for every
  surface that takes one: the post composer (issue #2104) and a message
  (#2110).

  Each of these is a sentence somebody can act on: "that file could not be
  processed" tells a member with a password-protected PDF nothing. That is also
  why they live here rather than being copied per surface — the second copy is
  where a refusal drifts into a different sentence for the same reason, and
  where the same reason acquires a second msgid to translate.

  Two of them do differ per surface, and only because they **enumerate what
  this surface accepts**: a post takes documents, a message takes documents and
  pictures. `pictures?: true` picks that half.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [megabyte_label: 1]

  alias Vutuv.Attachments

  @doc """
  The sentence for one refusal from `Vutuv.Attachments.create_pending/3`.
  `pictures?: true` where the surface also takes photographs.
  """
  def error_message(reason, opts \\ [])

  def error_message(:too_large, _opts),
    do: gettext("Files may be up to %{size}.", size: megabyte_label(Attachments.max_filesize()))

  def error_message(:invalid_file, opts) do
    if Keyword.get(opts, :pictures?, false) do
      gettext("Only PDF, plain text, Markdown and picture files can be attached.")
    else
      gettext("Only PDF, plain text and Markdown files can be attached.")
    end
  end

  def error_message(:pdf_unavailable, opts) do
    if Keyword.get(opts, :pictures?, false) do
      gettext("PDFs cannot be checked on this site. Text, Markdown and pictures can.")
    else
      gettext("PDFs cannot be checked on this site. Text and Markdown files can.")
    end
  end

  def error_message(:encrypted, _opts),
    do: gettext("This PDF is password-protected, so it cannot be checked.")

  # "uploaded" rather than "published": the same refusal reaches a private
  # message, which is not published at all.
  def error_message(:javascript, _opts),
    do: gettext("This PDF contains a program, which cannot be uploaded here.")

  def error_message(:open_action, _opts),
    do: gettext("This PDF does something when it is opened, which cannot be uploaded here.")

  def error_message(:embedded_files, _opts),
    do: gettext("This PDF has another file inside it, which cannot be uploaded here.")

  def error_message(:unreadable, _opts), do: gettext("This PDF could not be read.")

  def error_message(:invalid_image, _opts), do: gettext("This picture could not be read.")

  def error_message(:daily_budget, _opts),
    do: gettext("You have used up today's upload allowance. It frees up again over the day.")

  def error_message(:monthly_budget, _opts),
    do: gettext("You have used up this month's upload allowance.")

  def error_message(_reason, _opts), do: gettext("That file could not be processed.")
end
