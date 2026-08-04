defmodule Vutuv.Export do
  @moduledoc """
  The personal data export (GDPR Art. 20): everything vutuv stores about one
  member, as a single JSON-encodable map. Strictly owner-only — the
  controller guards — because it contains private data (all email
  addresses, direct messages, bookings).

  When a new per-user subsystem lands, add its section here, the same way
  `Vutuv.Accounts.delete_user/1` must learn to delete it.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Ads.Ad
  alias Vutuv.Chat.{Conversation, Participant}
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Jobs.{JobPostingBookmark, JobPostingLike}
  alias Vutuv.Organizations.{OrganizationBookmark, OrganizationLike}
  alias Vutuv.Posts.{Post, PostBookmark, PostDraft, PostLike, PostRepost}
  alias Vutuv.Repo
  alias Vutuv.Social.{Block, Follow, UserBookmark, UserLike}
  alias Vutuv.Tags.UserTagEndorsement

  # 2: "connections" became a derived mutual follow (not a stored table) and the
  #    connection-request email opt-in was removed.
  # 3: added the member/organization/job saves (bookmarks + likes) and the block
  #    list — per-user data that delete_user/1 removes but the export had missed.
  # 4: a work experience carries the name of the credential it was earned with
  #    (issue #858).
  # 5: the account-activity log (issue #1087) — what changed on the account,
  #    when, from where and how it was confirmed.
  # 6: composer drafts (issue #1148) — posts the member started but never sent.
  # 7: the accounts followed on other networks (issue #1160).
  # 8: `fediverse_likes` covers liked **replies** too (issue #1270) and every
  #    entry names which it is in `kind`.
  @schema_version 8

  def build(%User{} = user) do
    user =
      Repo.preload(user, [
        :emails,
        :phone_numbers,
        :addresses,
        :work_experiences,
        :educations,
        :qualifications,
        :languages,
        :social_media_accounts,
        :urls,
        :search_terms,
        :username_changes,
        user_tags: [:tag]
      ])

    # Resolves a job's cited credential (issue #858) by name from the already-
    # loaded, unfiltered qualifications list — no extra preload needed.
    qualification_names = Map.new(user.qualifications, &{&1.id, &1.name})

    %{
      schema_version: @schema_version,
      generated_at: DateTime.utc_now(:second),
      profile: profile(user),
      emails:
        Enum.map(
          user.emails,
          &%{value: &1.value, type: &1.email_type, public: &1.public?, added_at: &1.inserted_at}
        ),
      phone_numbers: Enum.map(user.phone_numbers, &%{value: &1.value, type: &1.number_type}),
      addresses:
        Enum.map(
          user.addresses,
          &Map.take(&1, [
            :description,
            :line_1,
            :line_2,
            :line_3,
            :line_4,
            :zip_code,
            :city,
            :state,
            :country
          ])
        ),
      work_experiences:
        Enum.map(
          user.work_experiences,
          fn work ->
            work
            |> Map.take([
              :organization,
              :title,
              :description,
              :kind,
              :start_month,
              :start_year,
              :end_month,
              :end_year
            ])
            # The credential this job cites (issue #858), by name — the
            # qualification itself is in the export's own section.
            |> Map.put(:qualification, qualification_names[work.qualification_id])
          end
        ),
      educations:
        Enum.map(
          user.educations,
          &Map.take(&1, [
            :school,
            :degree,
            :field_of_study,
            :description,
            :kind,
            :start_month,
            :start_year,
            :end_month,
            :end_year
          ])
        ),
      qualifications:
        Enum.map(
          user.qualifications,
          &Map.take(&1, [
            :name,
            :kind,
            :issuer,
            :awarded_month,
            :awarded_year,
            :expires_month,
            :expires_year,
            :credential_id,
            :url
          ])
        ),
      languages:
        Enum.map(user.languages, &%{code: &1.language_code, proficiency: &1.proficiency}),
      social_media_accounts:
        Enum.map(user.social_media_accounts, &%{provider: &1.provider, value: &1.value}),
      links: Enum.map(user.urls, &%{url: &1.value, description: &1.description}),
      tags: Enum.map(user.user_tags, & &1.tag.name),
      endorsements_given: endorsements_given(user),
      search_terms: Enum.map(user.search_terms, & &1.value),
      username_history:
        Enum.map(user.username_changes, &%{username: &1.value, changed_at: &1.inserted_at}),
      followers: follow_side(user, :followee_id, :follower),
      following: follow_side(user, :follower_id, :followee),
      connections: connections(user),
      posts: posts(user),
      # Posts that were started and never sent (issue #1148). The composer
      # stores them so a reload cannot eat them, which makes them the member's
      # own content sitting on our server — so they belong in the export just
      # as much as a published post does.
      drafts: drafts(user),
      likes: engagement(user, PostLike),
      bookmarks: engagement(user, PostBookmark),
      reposts: engagement(user, PostRepost),
      conversations: conversations(user),
      ad_bookings: ad_bookings(user),
      blocked_members: blocks(user),
      content_filters: content_filters(user),
      # The account-activity log (issue #1087): the member's own record of what
      # changed on their account. Personal data by definition, so Art. 20 covers
      # it — and it is the section that answers "was that me?".
      account_events: Vutuv.AccountEvents.export(user),
      saved_members: %{
        bookmarked: saved_users(user, UserBookmark),
        liked: saved_users(user, UserLike)
      },
      saved_organizations: %{
        bookmarked: saved_organizations(user, OrganizationBookmark),
        liked: saved_organizations(user, OrganizationLike)
      },
      saved_jobs: %{
        bookmarked: saved_jobs(user, JobPostingBookmark),
        liked: saved_jobs(user, JobPostingLike)
      },
      # The accounts the member follows on other networks (issue #1160). Their
      # own remote followers are deliberately absent: those rows are about other
      # people, and this export is the member's data.
      fediverse_following: fediverse_following(user),
      # What they liked on other networks (issues #1164 and #1270). Unambiguously
      # their own data — an act of theirs, recorded here — so Art. 20 covers it,
      # the same way the saved_* sections above are covered.
      fediverse_likes: fediverse_likes(user)
    }
  end

  # Posts by accounts the member follows and replies written under vutuv posts,
  # in one list: to the member both are "something on another network I liked",
  # and splitting them into two sections by which of our tables happens to hold
  # them would be an export of our schema rather than of their acts. `kind`
  # names which is which.
  defp fediverse_likes(user) do
    post_likes(user) ++ note_likes(user)
  end

  defp post_likes(user) do
    user
    |> Fediverse.list_remote_likes()
    |> Enum.map(fn {post, account} ->
      %{
        kind: "post",
        post: RemotePost.origin(post),
        author: RemoteAccount.display_handle(account),
        server: account.host,
        at: post.published_at
      }
    end)
  end

  defp note_likes(user) do
    user
    |> Fediverse.list_note_likes()
    |> Enum.map(fn note ->
      %{
        kind: "reply",
        post: Note.origin(note),
        author: Note.display_handle(note),
        server: Note.host(note.actor_uri),
        at: note.received_at
      }
    end)
  end

  defp fediverse_following(user) do
    user
    |> Fediverse.list_remote_follows()
    |> Enum.map(fn follow ->
      %{
        account: follow.remote_account.actor_uri,
        handle: RemoteAccount.display_handle(follow.remote_account),
        server: follow.remote_account.host,
        state: follow.state,
        muted: follow.muted,
        at: follow.inserted_at
      }
    end)
  end

  # The member's private content filters (issue #940): owner-only data, so it
  # belongs in their GDPR export.
  defp content_filters(user) do
    Enum.map(Vutuv.ContentFilters.list_for_user(user), fn f ->
      %{kind: f.kind, pattern: f.pattern, whole_word: f.whole_word, added_at: f.inserted_at}
    end)
  end

  defp blocks(user) do
    from(b in Block,
      where: b.blocker_id == ^user.id,
      join: u in assoc(b, :blocked),
      select: %{member: u.username, at: b.inserted_at}
    )
    |> Repo.all()
  end

  # The members / organizations / job postings this member privately saved
  # (bookmarked or liked). Each is a plain `user_id`-scoped read.
  defp saved_users(user, schema) do
    from(s in schema,
      where: s.user_id == ^user.id,
      join: u in assoc(s, :target_user),
      select: %{member: u.username, at: s.inserted_at}
    )
    |> Repo.all()
  end

  defp saved_organizations(user, schema) do
    from(s in schema,
      where: s.user_id == ^user.id,
      join: o in assoc(s, :organization),
      select: %{organization: o.name, slug: o.slug, at: s.inserted_at}
    )
    |> Repo.all()
  end

  defp saved_jobs(user, schema) do
    from(s in schema,
      where: s.user_id == ^user.id,
      join: j in assoc(s, :job_posting),
      select: %{job: j.title, slug: j.slug, at: s.inserted_at}
    )
    |> Repo.all()
  end

  defp profile(user) do
    %{
      username: user.username,
      first_name: user.first_name,
      middle_name: user.middle_name,
      last_name: user.last_name,
      nickname: user.nickname,
      honorific_prefix: user.honorific_prefix,
      honorific_suffix: user.honorific_suffix,
      name_pronunciation: user.name_pronunciation,
      # The gender answer belongs in the member's own GDPR export (Art. 15
      # covers everything stored about them, and this is the one surface that
      # shows it back to them) precisely because it appears on no public one.
      gender: user.gender,
      birthdate: user.birthdate,
      headline: user.headline,
      locale: user.locale,
      noindex: user.noindex?,
      noai: user.noai?,
      fediverse_followers: user.fediverse_followers?,
      also_known_as: user.also_known_as,
      moved_to: user.moved_to,
      notification_emails: user.notification_emails?,
      email_on_endorsement: user.email_on_endorsement?,
      email_on_follower: user.email_on_follower?,
      cv_update_notifications: user.cv_update_notifications?,
      identity_verified: user.identity_verified?,
      avatar_file: user.avatar,
      cover_photo_file: user.cover_photo,
      registered_at: user.inserted_at
    }
  end

  defp endorsements_given(user) do
    from(e in UserTagEndorsement,
      where: e.user_id == ^user.id,
      join: ut in assoc(e, :user_tag),
      join: t in assoc(ut, :tag),
      join: owner in assoc(ut, :user),
      select: %{tag: t.name, member: owner.username, at: e.inserted_at}
    )
    |> Repo.all()
  end

  defp follow_side(user, filter_field, other_assoc) do
    from(f in Follow,
      where: field(f, ^filter_field) == ^user.id,
      join: u in assoc(f, ^other_assoc),
      select: %{username: u.username, since: f.inserted_at}
    )
    |> Repo.all()
  end

  # A "connection" (vernetzt) is a mutual follow now, not a stored row: the
  # self-join keeps only the followees who follow back. `since` is the later of
  # the two follow times - the moment the relationship became mutual.
  defp connections(user) do
    from(out in Follow,
      join: back in Follow,
      on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
      where: out.follower_id == ^user.id,
      join: o in assoc(out, :followee),
      select: %{
        with: o.username,
        since:
          type(fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at), :naive_datetime)
      }
    )
    |> Repo.all()
  end

  defp posts(user) do
    from(p in Post,
      where: p.user_id == ^user.id,
      order_by: [asc: p.id],
      preload: [:tags, :images, :denials]
    )
    |> Repo.all()
    |> Enum.map(fn post ->
      %{
        id: post.id,
        body: post.body,
        published_on: post.published_on,
        created_at: post.inserted_at,
        updated_at: post.updated_at,
        tags: Enum.map(post.tags, & &1.name),
        images:
          Enum.map(post.images, &%{token: &1.token, alt: &1.alt, content_type: &1.content_type}),
        audience_denials: Enum.map(post.denials, &denial/1)
      }
    end)
  end

  defp drafts(user) do
    from(d in PostDraft, where: d.user_id == ^user.id, order_by: [asc: d.id])
    |> Repo.all()
    |> Enum.map(fn draft ->
      %{
        body: draft.body,
        tags: draft.tags,
        # Which composer it belongs to: a new post, an answer to one of our
        # posts, or an answer to a reply from another network.
        replying_to_post_id: draft.parent_id,
        replying_to_remote_note_id: draft.remote_note_id,
        image_count: length(draft.image_ids),
        started_at: draft.inserted_at,
        last_edited_at: draft.updated_at
      }
    end)
  end

  defp denial(d) do
    %{wildcard: d.wildcard, denied_user_id: d.denied_user_id}
  end

  # Likes / bookmarks / reposts share the shape {post, user, inserted_at};
  # the rows reference live posts only (engagement is deleted with the post).
  defp engagement(user, schema) do
    from(x in schema,
      where: x.user_id == ^user.id,
      join: p in assoc(x, :post),
      join: author in assoc(p, :user),
      select: %{post_id: p.id, author: author.username, at: x.inserted_at}
    )
    |> Repo.all()
  end

  defp conversations(user) do
    from(c in Conversation,
      join: part in Participant,
      on: part.conversation_id == c.id and part.user_id == ^user.id,
      order_by: [asc: c.id],
      preload: [participants: :user, messages: :sender]
    )
    |> Repo.all()
    |> Enum.map(fn c ->
      others =
        for p <- c.participants, p.user_id != user.id, p.user, do: p.user.username

      %{
        with: others,
        status: c.status,
        started_at: c.inserted_at,
        messages:
          Enum.map(
            c.messages,
            &%{from: &1.sender && &1.sender.username, body: &1.body, at: &1.inserted_at}
          )
      }
    end)
  end

  defp ad_bookings(user) do
    from(a in Ad, where: a.user_id == ^user.id, order_by: [asc: a.day])
    |> Repo.all()
    |> Enum.map(fn ad ->
      %{
        day: ad.day,
        content: ad.content,
        price_cents: ad.price_cents,
        approved: ad.approved_at != nil,
        billing:
          Map.take(ad, [
            :billing_name,
            :billing_company,
            :billing_street,
            :billing_zip_code,
            :billing_city,
            :billing_country,
            :vat_id
          ])
      }
    end)
  end
end
