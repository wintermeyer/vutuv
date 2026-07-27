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

      /:username/actor                       the actor document (id)
      /:username/actor/inbox                 POST target for Follow/Undo
      /:username/actor/followers             count-only collection
      /:username/actor/following             count-only collection (issue #1160)
      /:username/actor/outbox                count-only collection
      /:username/actor/collections/featured  the pinned post (issue #1110)

  The one exception is the installation-wide `endpoints.sharedInbox` (issue
  #1073), which belongs to nobody in particular and therefore lives under
  `/system/` — see `shared_inbox_url/0`.
  """

  alias Vutuv.Fediverse.Actor
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.ReviewCover
  alias VutuvWeb.PostComponents
  alias VutuvWeb.UserHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"

  # Everything note/2 reads off a post. Kept here, beside the builder that needs
  # it, because two call sites load it (the delivery queue and the permalink's
  # ActivityPub rendering) and a field added to the Note must not silently render
  # as `NotLoaded` at one of them.
  @note_preloads [:images, :review, :remote_reply_ref, reply_ref: [:parent_author]]

  @doc "The associations `note/2` needs loaded on a post."
  def note_preloads, do: @note_preloads

  def actor_url(user), do: "#{base()}/#{user.username}/actor"
  def key_id(user), do: actor_url(user) <> "#main-key"
  def note_url(user, post_id), do: "#{base()}/#{user.username}/posts/#{post_id}"

  @doc """
  The one inbox the whole installation offers (issue #1073), advertised as
  `endpoints.sharedInbox` in every actor document so a server with many
  followers here delivers a broadcast **once** instead of once per member — the
  efficiency we already take advantage of when we deliver outward.

  It is the only Fediverse URL that does not hang off a member, so it lives
  under `/system/` rather than at a root word: profiles own the URL root, and a
  new root segment would permanently burn a word a member could otherwise claim
  as a handle. Nothing is lost by the odd-looking path — remote servers only
  ever read it out of the actor document.
  """
  def shared_inbox_url, do: "#{base()}/system/inbox"

  @doc """
  The `featured` collection: the member's pinned post (issue #1110), which is
  how Mastodon and friends show a pinned post at the top of the profile they
  render. The path is the one those servers already expect.
  """
  def featured_url(user), do: actor_url(user) <> "/collections/featured"

  @doc "The `followers` collection, served count-only."
  def followers_url(user), do: actor_url(user) <> "/followers"

  @doc "The `outbox` collection, served count-only."
  def outbox_url(user), do: actor_url(user) <> "/outbox"

  @doc """
  The `following` collection (issue #1160): the accounts on other networks this
  member follows. Served count-only, exactly like `followers` — a remote server
  needs to know the actor follows *somebody* to render a sensible profile, and
  nobody needs the names.
  """
  def following_url(user), do: actor_url(user) <> "/following"

  @doc """
  A collection that publishes only how big it is: `followers`, `following` and
  `outbox` are all served this way, so the shape lives here with every other
  document rather than three times in the controller that answers them.
  """
  def count_collection(id, total) when is_binary(id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "OrderedCollection",
      "totalItems" => total
    }
  end

  @doc """
  The member's Fediverse address without the leading `@`
  (`member@vutuv.de`) — the `acct:` form WebFinger answers under and remote
  servers resolve. The host is this installation's, so it is right on
  vutuv.de and on anybody else's vutuv.
  """
  def acct(user), do: "#{user.username}@#{VutuvWeb.Endpoint.host()}"

  @doc "The same address the way it is written for humans: `@member@vutuv.de`."
  def handle(user), do: "@" <> acct(user)

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
      "outbox" => outbox_url(user),
      "followers" => followers_url(user),
      # Count-only like the followers collection, and for the same reason: who
      # a member reads is theirs to know (issue #1160). Always advertised, so a
      # remote server never has to guess whether this actor can follow back.
      "following" => following_url(user),
      # The installation-wide inbox (issue #1073). The per-member one above is
      # what every server already knows and keeps working forever; this is the
      # offer to deliver a broadcast once for all of them.
      "endpoints" => %{"sharedInbox" => shared_inbox_url()},
      # Where a remote server looks for the pinned post (issue #1110). Always
      # advertised, even with nothing pinned: the collection is then simply
      # empty, and an actor that only sometimes names the field would make the
      # profile a remote server renders depend on when it last fetched.
      "featured" => featured_url(user),
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
    |> put_also_known_as(user)
    |> put_moved_to(user)
  end

  # The accounts the member is migrating *from* (issue #986). Rendered only
  # when set: a remote server that moves followers here checks that its origin
  # account is one of these aliases, so an empty list must be absent, never an
  # empty array that reads as "claims nothing".
  defp put_also_known_as(doc, user) do
    case user.also_known_as do
      [_ | _] = aliases -> Map.put(doc, "alsoKnownAs", aliases)
      _ -> doc
    end
  end

  # The account the member redirected their followers *to* (issue #986, half 2).
  # Present only after a move: remote servers show a "moved to" notice and steer
  # follows to the target instead of this actor.
  defp put_moved_to(doc, %{moved_to: uri}) when is_binary(uri), do: Map.put(doc, "movedTo", uri)
  defp put_moved_to(doc, _user), do: doc

  @doc """
  Move: the redirect broadcast to every follower inbox (issue #986). Both
  `object` and `actor` are the member's own actor; `target` is the account they
  moved to. A compliant server re-points its follow to `target` once that
  account lists this actor in its `alsoKnownAs`.
  """
  def move_activity(user, target) do
    actor_url = actor_url(user)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url <> "#moves/" <> Vutuv.UUIDv7.generate(),
      "type" => "Move",
      "actor" => actor_url,
      "object" => actor_url,
      "target" => target,
      "to" => [actor_url <> "/followers"]
    }
  end

  @doc """
  Delete: the member's own actor is gone (issue #985). Broadcast to their
  follower inboxes when the account is deleted so remote servers purge the
  actor and the copies of its posts. Best effort — remote deletion is advisory
  by protocol, so this is a courtesy, never a guarantee.
  """
  def actor_delete_activity(user) do
    actor_url = actor_url(user)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url <> "#delete",
      "type" => "Delete",
      "actor" => actor_url,
      "object" => actor_url,
      "to" => [@public]
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
  def delete_activity(post_id, user), do: tombstone_activity(note_url(user, post_id), user)

  @doc """
  Delete(Tombstone) for an **explicit** Note id (issue #1102).

  A revocation names the id the receiving server actually stored, which is not
  always the one `note_url/2` builds today: that id carries the username, so
  after a rename (issue #1086) a Tombstone built from the current username
  matches nothing on the other end. `Vutuv.Fediverse` keeps the published id per
  delivery and passes it here.
  """
  def tombstone_activity(note_url, user) when is_binary(note_url) do
    envelope(user, "Delete", note_url <> "#delete", %{
      "id" => note_url,
      "type" => "Tombstone"
    })
  end

  @doc """
  Flag: a reply that came from another network was reported here, so the
  moderators of its home server hear about it (issue #1102). Mastodon files an
  incoming `Flag` as a report.

  `object` is a **list** — the shape those servers send and expect — naming the
  reported note and the account that wrote it. Nothing else travels: no content,
  no category, and above all not who reported it.

  The `content` line is a fixed English sentence rather than a `gettext/1` one on
  purpose. It is read by a stranger's moderation team, not by a vutuv member, so
  it must not depend on the reporter's browser language; and a fixed sentence
  cannot leak anything a member typed.
  """
  def flag_activity(user, object_uri, actor_uri) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => actor_url(user) <> "#flags/" <> Vutuv.UUIDv7.generate(),
      "type" => "Flag",
      "actor" => actor_url(user),
      "object" => [object_uri, actor_uri],
      "content" =>
        "Reported by a member of #{VutuvWeb.Endpoint.host()} as inappropriate. " <>
          "The copy stored there has been removed."
    }
  end

  @doc """
  Announce: `reposter` boosts `author`'s public Note to the reposter's own
  followers (issue #910). The object is a bare Note id — a URI string — which
  is why the reposted author must federate too: a non-federating author serves
  no Note at that URL, so a remote server could not render the boost.
  """
  def announce_activity(%Post{} = post, author, reposter) do
    envelope(reposter, "Announce", announce_id(post, author, reposter), note_url(author, post.id))
  end

  @doc """
  Undo(Announce): `reposter` takes their boost back. The wrapped Announce
  carries the same stable id the original Announce had, so a remote server can
  match and drop it.
  """
  def undo_announce_activity(%Post{} = post, author, reposter) do
    reposter_actor = actor_url(reposter)

    envelope(reposter, "Undo", announce_id(post, author, reposter) <> "#undo", %{
      "id" => announce_id(post, author, reposter),
      "type" => "Announce",
      "actor" => reposter_actor,
      "object" => note_url(author, post.id)
    })
  end

  # Stable per (reposted note, reposter), so the Undo references the same
  # Announce the repost sent.
  defp announce_id(%Post{id: post_id}, author, reposter),
    do: note_url(author, post_id) <> "#announce-" <> reposter.username

  @doc """
  The `featured` collection document (issue #1110): the member's pinned post
  as a full Note, so a remote server can render it without a second fetch —
  the shape Mastodon serves and expects. `posts` is a list (empty = nothing
  pinned, or a pin the anonymous public may not see), so the collection can
  grow past one entry without changing the document.
  """
  def featured_collection(user, posts) when is_list(posts) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => featured_url(user),
      "type" => "OrderedCollection",
      "totalItems" => length(posts),
      "orderedItems" => Enum.map(posts, &note(&1, user))
    }
  end

  @doc """
  Add(Note -> featured): the member pinned a post (issue #1110). Sent to the
  follower inboxes so a remote profile shows the pin without waiting for its
  next actor refresh; the collection itself stays the authority.
  """
  def add_featured_activity(%Post{id: post_id}, user), do: featured_activity("Add", post_id, user)

  @doc """
  Remove(Note -> featured): the pin was released or replaced. Takes the bare
  post id, because the row is often already gone (or replaced) by the time
  this is built.
  """
  def remove_featured_activity(post_id, user) when is_binary(post_id),
    do: featured_activity("Remove", post_id, user)

  # Both carry the Note's **id** rather than the object: the receiving server
  # already knows the post (it was delivered as a Create), and the collection
  # is what it re-reads when it wants the full thing.
  defp featured_activity(type, post_id, user) do
    note_url = note_url(user, post_id)

    user
    |> envelope(type, note_url <> "##{String.downcase(type)}-featured", note_url)
    |> Map.put("target", featured_url(user))
  end

  @doc """
  The id of the `Follow` a member sends, built from the id of the row that
  records it (issue #1160).

  Minted here beside `#main-key`, `#flags/` and `#accepts/` rather than in the
  context, so one module owns every fragment scheme our actor URLs carry — even
  though this is the one id that has to exist *before* its row is inserted,
  because the `Accept` that comes back finds the follow by this string.
  """
  def follow_activity_id(user, follow_id), do: actor_url(user) <> "#follows/" <> follow_id

  @doc """
  Follow: a member here asks to follow an account on another network (issue
  #1160).

  `activity_id` is minted by `Vutuv.Fediverse` from the stored follow row and
  is the join between the two halves of the handshake: the other server echoes
  it back inside its `Accept` or `Reject`, and that is how the answer finds the
  row it belongs to.

  Addressed to the target alone, never to the public collection: a follow
  request is a message to one account, not an announcement. That is also why it
  carries no `cc` to the member's own followers.
  """
  def follow_activity(user, target_actor_uri, activity_id) do
    user
    |> follow_object(target_actor_uri, activity_id)
    |> Map.put("@context", "https://www.w3.org/ns/activitystreams")
  end

  # The Follow itself, without the JSON-LD context: it is the top-level
  # document's job, and repeating it on a nested object is noise.
  defp follow_object(user, target_actor_uri, activity_id) do
    %{
      "id" => activity_id,
      "type" => "Follow",
      "actor" => actor_url(user),
      "object" => target_actor_uri,
      "to" => [target_actor_uri]
    }
  end

  @doc """
  Undo(Follow): the member unfollows again. The wrapped Follow repeats the id
  the original carried, so the remote server can match it and drop the
  relationship rather than guess from actor and object.
  """
  def undo_follow_activity(user, target_actor_uri, activity_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id <> "#undo",
      "type" => "Undo",
      "actor" => actor_url(user),
      "object" => follow_object(user, target_actor_uri, activity_id),
      "to" => [target_actor_uri]
    }
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
    remote = remote_target(post)

    %{
      "id" => note_url(user, post.id),
      "type" => "Note",
      "attributedTo" => actor_url(user),
      "content" => content_html(post, remote),
      "published" => iso8601(post.inserted_at),
      "to" => [@public],
      "cc" => cc(user, remote),
      "url" => note_url(user, post.id)
    }
    |> put_in_reply_to(post, remote)
    |> put_tag(remote)
    |> put_attachments(post)
  end

  # The reply from another network this post answers, when it answers one
  # (issue #1070). An un-preloaded association is a truthy `NotLoaded`, so it is
  # matched away explicitly rather than treated as "no target".
  defp remote_target(%Post{remote_reply_ref: %PostRemoteReply{} = ref}), do: ref
  defp remote_target(%Post{}), do: nil

  # A public answer is addressed like any other public post, plus the person it
  # answers. Naming them in `cc` (rather than `to`) is what Mastodon does for a
  # public reply: the post stays public, and the mentioned actor is delivered to
  # directly so it lands in their notifications.
  defp cc(user, nil), do: [actor_url(user) <> "/followers"]

  defp cc(user, %PostRemoteReply{actor_uri: actor_uri}),
    do: [actor_url(user) <> "/followers", actor_uri]

  # The `Mention` tag is what makes the remote server notify the person answered
  # and thread the reply under theirs.
  #
  # It is built from the **stored** actor URI, never from parsing the member's
  # typed text. Parsing would let anyone put `@someone@anywhere` in a post body
  # and have vutuv mint a verified-looking Mention at an actor nobody ever
  # checked, which is mention spam with our signature on it.
  defp put_tag(note, nil), do: note

  defp put_tag(note, %PostRemoteReply{} = ref) do
    Map.put(note, "tag", [
      %{
        "type" => "Mention",
        "href" => ref.actor_uri,
        "name" => mention_handle(ref)
      }
    ])
  end

  # How the answered account is written: the `@user@host` captured with the note.
  # Falls back to the bare host when the remote document carried no
  # `preferredUsername` (the same fallback `Vutuv.Fediverse.Note` makes).
  defp mention_handle(%PostRemoteReply{handle: handle}) when is_binary(handle) and handle != "",
    do: handle

  defp mention_handle(%PostRemoteReply{actor_uri: actor_uri}) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> "@" <> host
      _ -> actor_uri
    end
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
  defp content_html(post, remote) do
    body_html =
      post.body
      |> VutuvWeb.Markdown.render_post(images(post))
      |> Phoenix.HTML.safe_to_string()

    (mention_html(remote) <> body_html <> PostComponents.review_content_html(post))
    |> absolutize()
  end

  # The answered account, written into the outgoing HTML the way these networks
  # write a reply: a leading linked `@user@host`.
  #
  # It is added **here, on the wire, only** — the member's stored body does not
  # carry it. On vutuv the answer shows a "Replying to" line instead, so a member
  # who has never heard of Mastodon does not have to type a handle in a foreign
  # format, and their post does not read like a foreign one. The handle is remote
  # supplied, so it is escaped.
  defp mention_html(nil), do: ""

  defp mention_html(%PostRemoteReply{} = ref) do
    handle =
      ref |> mention_handle() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    href = ref.actor_uri |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    ~s(<p><span class="h-card"><a href="#{href}" class="u-url mention">#{handle}</a></span></p>)
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

  # An answer to a reply from another network points at **that** note (issue
  # #1070), not at the vutuv post underneath: the remote note already carries its
  # own `inReplyTo` back to our post, so this is what puts the answer in the right
  # place in the conversation on the other server. The URI is the durable copy
  # from the sidecar, so it still resolves after the cached note is collected.
  defp put_in_reply_to(note, _post, %PostRemoteReply{in_reply_to_uri: uri}),
    do: Map.put(note, "inReplyTo", uri)

  # Otherwise inReplyTo only when the parent's author federates too — a
  # non-federating author serves no Note at that id, and remote servers could
  # drop the post over an id that does not resolve.
  defp put_in_reply_to(note, post, nil) do
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
