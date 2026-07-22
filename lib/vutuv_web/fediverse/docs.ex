defmodule VutuvWeb.Fediverse.Docs do
  @moduledoc """
  The ActivityPub JSON documents for follow-only federation: the actor (a
  member's machine-readable identity, publishing the key deliveries are
  verified against), the Note a public post becomes, and the activity
  envelopes (Create/Update/Delete, plus the Accept a Follow is answered
  with). Lives in the web layer because everything here is URL building —
  like `VutuvWeb.AgentDocs`, which is the same idea for agents instead of
  Fediverse servers.

  URL scheme (all under the member, so nothing new burns a root slug):

      /:username/actor            the actor document (id)
      /:username/actor/inbox      POST target for Follow/Undo
      /:username/actor/followers  count-only collection
      /:username/actor/outbox     count-only collection
  """

  alias Vutuv.Fediverse.Actor
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReview
  alias Vutuv.ReviewCover
  alias VutuvWeb.PostComponents
  alias VutuvWeb.UserHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"

  def actor_url(user), do: "#{base()}/#{user.username}/actor"
  def key_id(user), do: actor_url(user) <> "#main-key"
  def note_url(user, post_id), do: "#{base()}/#{user.username}/posts/#{post_id}"

  @doc "The Person document WebFinger points at."
  def actor(user, %Actor{} = actor) do
    actor_url = actor_url(user)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => actor_url,
      "type" => "Person",
      "preferredUsername" => user.username,
      "name" => UserHelpers.full_name(user),
      "summary" => summary(user),
      "url" => "#{base()}/#{user.username}",
      "inbox" => actor_url <> "/inbox",
      "outbox" => actor_url <> "/outbox",
      "followers" => actor_url <> "/followers",
      "manuallyApprovesFollowers" => false,
      "published" => iso8601(user.inserted_at),
      "publicKey" => %{
        "id" => key_id(user),
        "owner" => actor_url,
        "publicKeyPem" => actor.public_key_pem
      },
      "icon" => %{
        "type" => "Image",
        "mediaType" => "image/jpeg",
        "url" => "#{base()}/#{user.username}/avatar.jpg"
      }
    }
  end

  @doc "Create(Note): a freshly published public post."
  def create_activity(%Post{} = post, user) do
    note = note(post, user)

    envelope(user, "Create", note["id"] <> "#create", note)
    |> Map.put("published", note["published"])
  end

  @doc "Update(Note): an edited public post (id unique per edit)."
  def update_activity(%Post{} = post, user) do
    note = note(post, user)
    stamp = post.updated_at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

    envelope(user, "Update", note["id"] <> "#update-#{stamp}", note)
  end

  @doc "Delete(Tombstone): a removed post (or one whose audience closed)."
  def delete_activity(post_id, user) do
    note_url = note_url(user, post_id)

    envelope(user, "Delete", note_url <> "#delete", %{
      "id" => note_url,
      "type" => "Tombstone"
    })
  end

  @doc "Accept(Follow): the answer that seals a remote follow."
  def accept_activity(user, follow_object) do
    id = actor_url(user) <> "#accepts/" <> Vutuv.UUIDv7.generate()

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Accept",
      "actor" => actor_url(user),
      "object" => follow_object
    }
  end

  @doc "The Note a public post federates as."
  def note(%Post{} = post, user) do
    %{
      "id" => note_url(user, post.id),
      "type" => "Note",
      "attributedTo" => actor_url(user),
      "content" => content_html(post),
      "published" => iso8601(post.inserted_at),
      "to" => [@public],
      "cc" => [actor_url(user) <> "/followers"],
      "url" => note_url(user, post.id)
    }
    |> put_in_reply_to(post)
    |> put_attachments(post)
  end

  defp envelope(user, type, id, object) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => type,
      "actor" => actor_url(user),
      "to" => [@public],
      "cc" => [actor_url(user) <> "/followers"],
      "object" => object
    }
  end

  # The same rendering members see, with every relative link/image made
  # absolute (remote servers render this HTML on their own domain). A review
  # sidecar is rendered INTO the content: the Note is one more rendering of
  # the post (like the agent docs), so a Mastodon reader gets the reviewed
  # work's facts even though remote software knows nothing of review cards.
  defp content_html(post) do
    body_html =
      post.body
      |> VutuvWeb.Markdown.render_post(images(post))
      |> Phoenix.HTML.safe_to_string()

    (body_html <> PostComponents.review_content_html(post))
    |> absolutize()
  end

  # Remote servers are anonymous viewers: only AI-released images may render
  # inline (released_images/1 also handles an un-preloaded association).
  defp images(post) do
    Posts.released_images(post)
  end

  # Root-relative src/href (post images, in-app links) must be absolute for a
  # remote server. A protocol-relative (`//host`) URL already resolves on its
  # own, so the negative lookahead leaves it alone instead of corrupting it
  # into `#{base()}//host` (the same guard as `VutuvWeb.Feeds.absolutize_urls/1`).
  defp absolutize(html) do
    VutuvWeb.Markdown.absolutize_html(html, base())
  end

  # inReplyTo only when the parent's author federates too — otherwise the id
  # would not resolve as ActivityPub and remote servers could drop the post.
  defp put_in_reply_to(note, post) do
    case reply_parent(post) do
      nil -> note
      {parent_author, parent_id} -> Map.put(note, "inReplyTo", note_url(parent_author, parent_id))
    end
  end

  defp reply_parent(%Post{reply_ref: %Ecto.Association.NotLoaded{}}), do: nil
  defp reply_parent(%Post{reply_ref: nil}), do: nil

  defp reply_parent(%Post{reply_ref: reply_ref}) do
    with %Vutuv.Accounts.User{} = author <- reply_ref.parent_author,
         true <- Vutuv.Fediverse.federated?(author),
         false <- Vutuv.Posts.restricted?(%Post{id: reply_ref.parent_post_id}) do
      {author, reply_ref.parent_post_id}
    else
      _ -> nil
    end
  end

  # Public posts only federate, and a public post's images are publicly
  # servable through the authorizing proxy — so their URLs can ride along.
  # A released review cover rides along as an attachment too — a public
  # post's cover is publicly servable through the authorizing proxy.
  defp put_attachments(note, post) do
    attachments =
      Enum.map(images(post), fn image ->
        %{
          "type" => "Document",
          "mediaType" => "image/avif",
          "url" => base() <> PostImage.url(image, "large")
        }
      end) ++ cover_attachments(post)

    case attachments do
      [] -> note
      attachments -> Map.put(note, "attachment", attachments)
    end
  end

  defp cover_attachments(%Post{review: %PostReview{} = review}) do
    if PostReview.cover_ready?(review) do
      [
        %{
          "type" => "Document",
          "mediaType" => "image/avif",
          "name" => review.title,
          "url" => base() <> ReviewCover.url(review)
        }
      ]
    else
      []
    end
  end

  defp cover_attachments(%Post{}), do: []

  defp summary(user) do
    case user.headline do
      nil ->
        ""

      "" ->
        ""

      headline ->
        "<p>" <>
          (headline |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <> "</p>"
    end
  end

  defp iso8601(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  defp base, do: String.trim_trailing(VutuvWeb.Endpoint.url(), "/")
end
