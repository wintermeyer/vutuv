defmodule VutuvWeb.Live.PostTranslations do
  @moduledoc """
  The shared host-side half of on-demand post translations (issue #1462),
  used by every LiveView that renders post cards (feed, permalink thread,
  profile). The cards themselves read a `translations` map — key
  `{:post | :remote_post | :note, id}`, value `:pending` or a
  `%Vutuv.Translations.Translation{}` (which means: shown) — and each host
  keeps that map in an assign, because how a change reaches the DOM differs
  per host (a plain re-render, or a `stream_insert` of the one affected
  entry).

  The flow: a card's "Translate" button fires `"translate"` with the subject
  kind + id; `request/3` authorizes the subject against the viewer, asks
  `Vutuv.Translations.request/2` (cache hit shows immediately, otherwise a
  job queues) and subscribes the host to the subject's topic; the worker's
  `{:translation_ready, …}` broadcast swaps the text in via `apply_ready/3`,
  and a `{:translation_failed, …}` just clears the pending line
  (`apply_failed/3`) — the card keeps showing the original. "Show the
  original" removes the map entry; the cached row stays, so translating
  again is instant.

  Nothing here renders on logged-out, agent-format or ActivityPub surfaces —
  hosts gate the whole feature with `available?/1`.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Translations
  alias Vutuv.Translations.Translation
  alias Vutuv.Translations.Worker

  @doc """
  Whether this viewer gets translation controls at all: the installation has
  the feature on, and somebody is signed in (public and logged-out surfaces
  always show the original).
  """
  def available?(viewer), do: Translations.enabled?() and match?(%User{}, viewer)

  @doc "The reader's translation target: their UI locale."
  def target_language, do: Gettext.get_locale(VutuvWeb.Gettext)

  @doc """
  Whether a card in `language` is worth offering a Translate action for: the
  language has to be **known** and different from the reader's target.

  An undeclared card (nil) gets nothing (issue #1535). It used to be offered,
  on the theory that an unknown language might be foreign — but nearly
  everything written before the language column existed is undeclared, so the
  offer sat under posts in the reader's own language and a tap spent a slot
  translating German into German. What fills those columns instead is
  `Vutuv.Translations.Detector`, and a detected language reaches this test like
  a declared one.

  Deliberately **wider** than `auto_translate?/1` + `auto_translation_wanted?`:
  the automatic mode leaves a card in one of the reader's *other* chosen
  languages alone, while the manual offer stands even there — a reader who
  ticked a language to see it in the original may still want one particular
  card translated, and that tap is theirs to make.
  """
  def offer_translation?(language),
    do: is_binary(language) and language != target_language()

  @doc """
  The translations map a host mounts with: an empty map when this viewer gets
  the controls (`available?/1`), nil when they do not. The cards read that
  difference straight off the one assign, so no second gate travels with it.
  """
  def initial_map(viewer), do: if(available?(viewer), do: %{})

  @doc """
  Handles a card's "Translate" click. Returns `{:ok, key, state}` with
  `state` either `:pending` or the cached `%Translation{}` (shown at once),
  or `:denied` for a subject this viewer may not read (a tampered id), the
  feature being off, or an unknown kind.
  """
  def request(viewer, kind, id) do
    with true <- available?(viewer),
         {:ok, subject} <- fetch_subject(kind, id, viewer),
         {:ok, state} <- track(subject) do
      {:ok, subject_key(subject), state}
    else
      _denied -> :denied
    end
  end

  # The one mapping from `Translations.request/2` to a card's state — a cache
  # hit shows at once, a queued job subscribes this host for the swap-in.
  # Shared by the click path above and the translate mode below.
  defp track(subject) do
    case Translations.request(subject, target_language()) do
      {:cached, translation} ->
        {:ok, translation}

      {:queued, _job} ->
        Phoenix.PubSub.subscribe(Vutuv.PubSub, Translations.topic(subject))
        {:ok, :pending}

      :disabled ->
        :denied
    end
  end

  @doc """
  Folds a worker `{:translation_ready, translation}` broadcast into the map:
  the entry flips from `:pending` to shown — but only if this host asked
  (the key is pending) and the translation is into this reader's language.
  Returns `{key, map}` or `:ignore`.
  """
  def apply_ready(map, %Translation{} = translation) do
    key = Translations.subject(translation)

    if map[key] == :pending and translation.target_language == target_language() do
      {key, Map.put(map, key, translation)}
    else
      :ignore
    end
  end

  @doc """
  Folds a `{:translation_failed, subject, target}` broadcast into the map:
  the pending line simply disappears and the card keeps the original.
  Returns `{key, map}` or `:ignore`.
  """
  def apply_failed(map, subject_key, target) do
    if map[subject_key] == :pending and target == target_language() do
      {subject_key, Map.delete(map, subject_key)}
    else
      :ignore
    end
  end

  @doc """
  Handles a card's "Show the original" click: drops the entry (the cached
  translation row stays, so translating again is instant). Returns
  `{key, map}` or `:ignore` for an unknown kind.
  """
  def show_original(map, kind, id) when is_map(map) do
    case parse_key(kind, id) do
      nil -> :ignore
      key -> {key, Map.delete(map, key)}
    end
  end

  # A viewer without the controls (nil map) has nothing to show or hide — a
  # hand-crafted event must not crash the host.
  def show_original(nil, _kind, _id), do: :ignore

  @doc ~S|The `{kind, id}` map key for a card's subject struct.|
  defdelegate subject_key(subject), to: Translations

  @doc """
  Whether this viewer's feed auto-translates (issue #1461): the feature is
  available to them AND they chose the "translate" mode for posts outside
  their languages.
  """
  def auto_translate?(viewer) do
    available?(viewer) and Vutuv.Prefs.get(viewer, :feed_foreign_posts) == "translate"
  end

  @doc """
  Translate mode's page hook: folds a freshly loaded page's subjects into the
  map — cached translations show at once (ONE batched query per page, never
  one per card), the rest queue with the pending line and the live swap-in.
  Unknown-language subjects count as the reader's own: never auto-translated,
  the manual button covers them. Already-decided keys are left alone, so a
  reader's "Show the original" survives a load-more.
  """
  def auto_translate(map, subjects, viewer) do
    target = target_language()
    chosen = Posts.chosen_feed_languages(viewer)

    wanted =
      subjects
      |> Enum.uniq_by(&subject_key/1)
      |> Enum.filter(&auto_translation_wanted?(map, &1, target, chosen))

    cached = Translations.fresh_translations(wanted, target)

    {map, queued?} =
      Enum.reduce(wanted, {map, false}, fn subject, {acc, queued?} ->
        case resolve_auto(acc, subject, cached[subject_key(subject)]) do
          {acc, true} -> {acc, true}
          {acc, false} -> {acc, queued?}
        end
      end)

    # One nudge for the page, not one per card: each costs the worker a full
    # drain round (a resume_stuck UPDATE plus the due SELECT).
    if queued?, do: Worker.nudge()

    map
  end

  defp auto_translation_wanted?(map, %{language: language} = subject, target, chosen) do
    is_binary(language) and language != target and language not in chosen and
      not Map.has_key?(map, subject_key(subject))
  end

  # `{map, queued_a_job?}` — the caller nudges the worker once for the page.
  defp resolve_auto(map, subject, %Translation{} = cached),
    do: {Map.put(map, subject_key(subject), cached), false}

  # `queue/2` rather than `Translations.request/2`: the batch above already
  # answered "is there a fresh translation for this subject", and `request/2`
  # would ask again, once per card.
  defp resolve_auto(map, subject, nil) do
    case Translations.queue(subject, target_language()) do
      {:queued, _job} ->
        Phoenix.PubSub.subscribe(Vutuv.PubSub, Translations.topic(subject))
        {Map.put(map, subject_key(subject), :pending), true}

      :disabled ->
        {map, false}
    end
  end

  # The subject behind a card's click, checked against the viewer: a post
  # must be visible to them (a tampered id must not spend translation budget
  # on somebody else's restricted post, even though the result would never
  # render); cached remote content is what logged-in members see anyway.
  defp fetch_subject("post", id, viewer) do
    with %Posts.Post{} = post <- Posts.get_post(id),
         true <- Posts.visible_to?(post, viewer) do
      {:ok, post}
    else
      _hidden -> :error
    end
  end

  defp fetch_subject("remote_post", id, _viewer) do
    case Fediverse.get_remote_post(id) do
      %Fediverse.RemotePost{} = remote -> {:ok, remote}
      nil -> :error
    end
  end

  defp fetch_subject("note", id, _viewer) do
    case Fediverse.get_note(id) do
      %Fediverse.Note{} = note -> {:ok, note}
      nil -> :error
    end
  end

  defp fetch_subject(_kind, _id, _viewer), do: :error

  defp parse_key("post", id), do: {:post, id}
  defp parse_key("remote_post", id), do: {:remote_post, id}
  defp parse_key("note", id), do: {:note, id}
  defp parse_key(_kind, _id), do: nil
end
