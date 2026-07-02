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
  alias Vutuv.Posts.{Post, PostBookmark, PostLike, PostRepost}
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.UserTagEndorsement

  # Bumped to 2 when "connections" stopped being a stored table and became a
  # derived mutual follow, and the connection-request email opt-in was removed.
  @schema_version 2

  def build(%User{} = user) do
    user =
      Repo.preload(user, [
        :emails,
        :phone_numbers,
        :addresses,
        :work_experiences,
        :educations,
        :social_media_accounts,
        :urls,
        :search_terms,
        :username_changes,
        user_tags: [:tag]
      ])

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
          &Map.take(&1, [
            :organization,
            :title,
            :description,
            :start_month,
            :start_year,
            :end_month,
            :end_year
          ])
        ),
      educations:
        Enum.map(
          user.educations,
          &Map.take(&1, [
            :school,
            :degree,
            :field_of_study,
            :description,
            :start_month,
            :start_year,
            :end_month,
            :end_year
          ])
        ),
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
      likes: engagement(user, PostLike),
      bookmarks: engagement(user, PostBookmark),
      reposts: engagement(user, PostRepost),
      conversations: conversations(user),
      ad_bookings: ad_bookings(user)
    }
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
      gender: user.gender,
      birthdate: user.birthdate,
      headline: user.headline,
      locale: user.locale,
      noindex: user.noindex?,
      noai: user.noai?,
      notification_emails: user.notification_emails?,
      email_on_endorsement: user.email_on_endorsement?,
      email_on_follower: user.email_on_follower?,
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
