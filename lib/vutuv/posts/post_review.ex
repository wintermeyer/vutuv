defmodule Vutuv.Posts.PostReview do
  @moduledoc """
  The structured **review sidecar** of a post: a member reviewing a book or a
  film attaches kind + identifier (ISBN / IMDb id) + display metadata to an
  ordinary post, and every surface that renders the post adds a review card
  (cover, title, creator, year, shop/IMDb link) on top of the prose. The body
  stays plain Markdown — "this post is a book review" is simply "the post has
  a review row", never body parsing. Future kinds (music, games, hotels…)
  join by extending `@kinds` and the per-kind identifier normalization.

  The **cover** is fetched from Open Library by ISBN (`Vutuv.Posts.ReviewCovers`,
  book reviews only) and follows the screenshot lifecycle: `cover_status`
  `none` → `pending` → `ready`/`failed`, with `cover` holding the
  content-fingerprinted filename and `cover_moderation` the AI-scan state
  (`Vutuv.Moderation.ImageScans` — an external image shown publicly is gated
  like any upload). The same background pass fills the **edition details**
  `pages`, `publisher` and — for an audiobook, from a library catalogue —
  `duration_minutes`. A changed ISBN resets the cover to `pending` and
  clears those details, so an edit re-fetches; the fields are set here in the
  changeset, never cast from params.
  """

  use VutuvWeb, :model

  alias Vutuv.Isbn
  alias Vutuv.Moderation.ImageScans

  @kinds ~w(book movie)
  @cover_statuses ~w(none pending ready failed)

  # How the reviewer consumed the work — a book review can say "I listened to
  # the audiobook", a film review "seen in the cinema". Optional, per kind.
  @media %{
    "book" => ~w(print ebook audiobook),
    "movie" => ~w(cinema streaming disc)
  }

  schema "post_reviews" do
    belongs_to(:post, Vutuv.Posts.Post)

    field(:kind, :string)
    field(:identifier, :string)
    field(:title, :string)
    field(:creator, :string)
    field(:year, :integer)
    field(:medium, :string)

    # Edition facts fetched with the cover, never cast from params: how many
    # pages the book has, who published this edition, and — for an audiobook
    # — how long it runs, in whole minutes.
    field(:pages, :integer)
    field(:publisher, :string)
    field(:duration_minutes, :integer)

    field(:cover, :string)
    field(:cover_status, :string, default: "none")
    field(:cover_moderation, :string)

    timestamps()
  end

  def kinds, do: @kinds
  def cover_statuses, do: @cover_statuses

  @doc "The medium choices of a kind (`\"book\"` → print/ebook/audiobook, …)."
  def media(kind), do: Map.get(@media, kind, [])

  def changeset(post_review, params \\ %{}) do
    post_review
    |> cast(params, [:kind, :identifier, :title, :creator, :year, :medium])
    |> update_change(:title, &String.trim/1)
    |> update_change(:creator, &String.trim/1)
    |> validate_required([:kind])
    # Standalone sentence: the composer surfaces these without field names.
    |> validate_required([:title], message: "the review is missing the title of the work")
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, max: 255)
    |> validate_length(:creator, max: 255)
    |> validate_number(:year, greater_than_or_equal_to: 1000, less_than_or_equal_to: 3000)
    |> normalize_medium()
    |> normalize_identifier()
    |> reconcile_cover_state()
  end

  # Blank medium (the select's "no answer") stores nil; a set one must fit
  # the review's kind, so a book can never claim "cinema".
  defp normalize_medium(changeset) do
    changeset =
      update_change(changeset, :medium, fn medium ->
        if medium && String.trim(medium) != "", do: medium
      end)

    case get_field(changeset, :medium) do
      nil -> changeset
      medium -> check_medium(changeset, medium)
    end
  end

  defp check_medium(changeset, medium) do
    if medium in media(get_field(changeset, :kind)) do
      changeset
    else
      add_error(changeset, :medium, "is invalid")
    end
  end

  # Canonicalizes what people paste — a hyphenated ISBN-10/13, a full IMDb
  # URL — into the one stored form per kind. Runs on the *change*, so an
  # unchanged identifier is never re-normalized (and never resets the cover).
  defp normalize_identifier(changeset) do
    case {get_field(changeset, :kind), get_change(changeset, :identifier)} do
      {_kind, nil} ->
        changeset

      {kind, value} ->
        case normalize(kind, String.trim(value)) do
          {:ok, normalized} -> put_change(changeset, :identifier, normalized)
          :empty -> put_change(changeset, :identifier, nil)
          :error -> add_error(changeset, :identifier, identifier_error(kind))
        end
    end
  end

  defp normalize(_kind, ""), do: :empty
  defp normalize("book", value), do: Isbn.normalize(value)
  defp normalize("movie", value), do: imdb_id(value)
  defp normalize(_kind, _value), do: :empty

  defp identifier_error("movie"), do: "is not a valid IMDb link"
  defp identifier_error(_kind), do: "is not a valid ISBN"

  # A bare IMDb title id, or one inside a pasted imdb.com URL.
  defp imdb_id(value) do
    cond do
      value =~ ~r/^tt\d{6,10}$/ ->
        {:ok, value}

      match = Regex.run(~r|imdb\.com/(?:[a-z-]+/)?title/(tt\d{6,10})|i, value) ->
        {:ok, Enum.at(match, 1)}

      true ->
        :error
    end
  end

  # Only a book with an ISBN has a fetchable cover (and fetchable edition
  # details). A new/changed ISBN queues a (re-)fetch; dropping the ISBN or
  # switching kinds clears cover and details alike, so nothing from the
  # previous edition lingers on the card.
  defp reconcile_cover_state(changeset) do
    identifier_changed? = Map.has_key?(changeset.changes, :identifier)
    book? = get_field(changeset, :kind) == "book"
    isbn? = book? and get_field(changeset, :identifier) != nil

    cond do
      not changeset.valid? ->
        changeset

      isbn? and (identifier_changed? or get_field(changeset, :cover_status) == "none") ->
        change(changeset,
          cover: nil,
          cover_status: "pending",
          cover_moderation: nil,
          pages: nil,
          publisher: nil,
          duration_minutes: nil
        )

      not isbn? and get_field(changeset, :cover_status) != "none" ->
        change(changeset,
          cover: nil,
          cover_status: "none",
          cover_moderation: nil,
          pages: nil,
          publisher: nil,
          duration_minutes: nil
        )

      true ->
        changeset
    end
  end

  @doc """
  Whether the fetched cover may render for the general public: fetched *and*
  released by the AI image scan. The author sees their own pending cover via
  `visible_cover?/2`'s owner clause instead.
  """
  def cover_ready?(%__MODULE__{cover_status: "ready", cover: cover, cover_moderation: moderation})
      when is_binary(cover),
      do: ImageScans.released?(moderation)

  def cover_ready?(%__MODULE__{}), do: false

  @doc """
  The shop link of a book review: the Amazon `/dp/` page of the ISBN-10 form
  (a 979 ISBN, which has none, gets a search link). `nil` for non-books,
  ISBN-less reviews, or when the operator blanked `:amazon_domain` — the
  per-installation off switch (see `config/runtime.exs`). An optional
  `:amazon_affiliate_tag` rides along as `?tag=`.
  """
  def amazon_url(%__MODULE__{kind: "book", identifier: isbn}) when is_binary(isbn) do
    case Application.get_env(:vutuv, :amazon_domain, "www.amazon.de") do
      blank when blank in [nil, ""] -> nil
      domain -> with_affiliate_tag("https://#{domain}" <> amazon_path(isbn))
    end
  end

  def amazon_url(%__MODULE__{}), do: nil

  defp amazon_path(isbn) do
    case Isbn.isbn10(isbn) do
      {:ok, isbn10} -> "/dp/#{isbn10}"
      :error -> "/s?k=#{isbn}"
    end
  end

  defp with_affiliate_tag(url) do
    case Application.get_env(:vutuv, :amazon_affiliate_tag) do
      blank when blank in [nil, ""] -> url
      tag -> url <> if(String.contains?(url, "?"), do: "&", else: "?") <> "tag=#{tag}"
    end
  end

  @doc "The IMDb title page of a film review, `nil` without an id."
  def imdb_url(%__MODULE__{kind: "movie", identifier: "tt" <> _ = id}) do
    "https://www.imdb.com/title/#{id}/"
  end

  def imdb_url(%__MODULE__{}), do: nil

  @doc """
  An Audible link for an **audiobook** review — a search for the book by its
  title (and author). Audible keys its audiobooks by their own ASIN, not the
  print ISBN we store, so a search is the closest reliable link to "the book
  on Audible". `nil` for anything but an audiobook, and when `AUDIBLE_DOMAIN`
  is blanked (the store switched off, like the Amazon link).
  """
  def audible_url(%__MODULE__{kind: "book", medium: "audiobook", title: title} = review)
      when is_binary(title) do
    case Application.get_env(:vutuv, :audible_domain, "www.audible.de") do
      blank when blank in [nil, ""] -> nil
      domain -> "https://#{domain}/search?keywords=#{audible_keywords(review)}"
    end
  end

  def audible_url(%__MODULE__{}), do: nil

  defp audible_keywords(%__MODULE__{title: title, creator: creator}) do
    [title, creator]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> URI.encode_www_form()
  end
end
