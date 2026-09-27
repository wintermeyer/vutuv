defmodule VutuvWeb.AttachmentController do
  @moduledoc """
  The one address a file has, under a message (issue #2110) or a post (issue
  #2108): the file itself, and the pictures of its first pages.

  Neither tree gets a `Plug.Static` mount or an nginx location
  (`Vutuv.AttachmentStore`), so every byte comes through here and every request
  asks `Vutuv.Attachments.readable_by?/2` again. That repetition is the point:
  a file travels only between two **connected** members, and a connection can
  be ended after the message was sent — a decision made once when the message
  went out would keep handing the file to somebody who is a stranger again.

  Denied and unknown are the same 404 (`VutuvWeb.ImageProxy.not_found/1`), so a
  token cannot be used to find out that a file exists.

  A file under a **post** follows the post's audience, so an anonymous reader
  fetches a public post's file here too. That is why the login check is
  `readable_by?/2`'s rather than a plug: it answers false for an anonymous
  reader everywhere else, with the same 404.
  """

  use VutuvWeb, :controller

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.AttachmentStore
  alias VutuvWeb.ImageProxy

  @doc """
  Hands the file over — always as a download, never inline: what comes back is
  a member's own bytes under their own name, and this app must not render a
  stranger's document on its own origin.

  Through `ImageProxy.hand_over_private/4`, which the moderation case page's
  download shares: `private, no-store` and the stored content type,
  because this URL does not answer the same way for ever — ending the
  connection closes it again, and a cached copy in a shared browser would
  outlive that.
  """
  def file(conn, %{"token" => token}) do
    with %Attachment{} = attachment <- readable(conn, token),
         path when is_binary(path) <- AttachmentStore.served_path(attachment.token) do
      ImageProxy.hand_over_private(conn, path, attachment.file_name, attachment.content_type)
    else
      _denied_or_missing -> ImageProxy.not_found(conn)
    end
  end

  @doc """
  One served size of one preview page — a page of a PDF, a text file drawn as a
  page, or, for a picture, the picture itself.

  The version is parsed against the declared whitelist, so `original.avif` and
  anything else that is not a size resolves to nothing rather than to a path.
  """
  def page(conn, %{"token" => token, "position" => position, "version" => version_file}) do
    with %Attachment{} = attachment <- readable(conn, token),
         version when is_binary(version) <-
           ImageProxy.parse_version(version_file, AttachmentStore.page_versions()),
         # `>= 0` is not tidiness: `AttachmentStore.page_dir/2` guards on it and
         # RAISES rather than answering nothing, so `pages/-1/lite.avif` came
         # back a 500 instead of the uniform 404 (measured in a browser,
         # 2026-09-11). Every other refusal here is a `nil`, so this one has to
         # be too.
         {index, ""} when index >= 0 <- Integer.parse(position),
         path when is_binary(path) <-
           AttachmentStore.page_version_path(attachment.token, index, version) do
      send_page(conn, attachment, path)
    else
      _denied_or_missing -> ImageProxy.not_found(conn)
    end
  end

  # A post's page is a size of a picture a feed renders, so it takes the photo
  # proxy's five-minute tier: a scroll past the same card costs no request, and
  # narrowing the post still reaches a browser that holds it within five
  # minutes (`VutuvWeb.ImageProxy`, issue #2170).
  defp send_page(conn, %Attachment{post_id: id}, path) when is_binary(id),
    do: ImageProxy.send_version(conn, path)

  defp send_page(conn, _message_file, path) do
    conn
    # `no-store` like the file, and this was **measured** rather than assumed
    # (2026-09-11): a `private, max-age=30` here — meant to save a thread of
    # pictures from re-fetching every thumbnail — served a stranger's browser
    # a 200 for a picture they had no right to, because `private` means "one
    # user's cache" and a browser profile does not know the session changed.
    # A shared computer is exactly where that lands. The re-fetch is the
    # price of a picture whose permission can be revoked.
    |> ImageProxy.put_no_store()
    |> put_resp_content_type(MIME.from_path(path), nil)
    |> send_file(200, path)
  end

  # The whole authorization, in one place for both actions: the row, then the
  # question. `readable_by?/2` is the context's, so the proxy cannot answer it
  # differently from the bubble that draws the chip.
  defp readable(conn, token) do
    with %Attachment{} = attachment <- Attachments.get_by_token(token),
         true <- Attachments.readable_by?(attachment, conn.assigns[:current_user]) do
      attachment
    else
      _no -> nil
    end
  end
end
