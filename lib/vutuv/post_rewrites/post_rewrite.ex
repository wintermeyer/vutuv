defmodule Vutuv.PostRewrites.PostRewrite do
  @moduledoc """
  One search-and-replace rule in a member's private list for one author
  (`Vutuv.PostRewrites`): a regular expression, what every match becomes, and
  its place in the order the account's rules run in.

  `account` is the author's handle as the app spells it — `@golemde@flipboard.com`
  for an account elsewhere, `@handle` for a member or a page — the same names
  `Vutuv.Posts.account_names/1` answers for any post, so one string column reads
  all three author kinds. `pattern` is PCRE with the unicode and multiline flags
  (`^` and `$` anchor lines, which is what somebody deleting a footer expects);
  `replacement` may use `\\1`…`\\9` for groups and `\\0` for the whole match, and
  an `&` in it is the literal character.

  Owner-only like a content filter: it reveals what a member does not want to
  read, so it is never public and rides along in the GDPR export.
  """

  use VutuvWeb, :model

  # A pattern long enough for any footer somebody wants gone, short enough that
  # compiling it can never be the expensive part; both sit inside varchar(255).
  @max_pattern 255
  @max_replacement 255

  # unicode + ucp is Elixir's `u` flag; multiline makes `^`/`$` line anchors.
  @compile_opts [:unicode, :ucp, :multiline]

  schema "post_rewrites" do
    belongs_to(:user, Vutuv.Accounts.User)
    field(:account, :string)
    field(:pattern, :string)
    field(:replacement, :string, default: "")
    field(:position, :integer)

    timestamps()
  end

  @doc "The maximum pattern length."
  def max_pattern, do: @max_pattern

  @doc """
  Changeset for a rule. `user_id`, `account` and `position` are set by the
  context, never cast, so a request can only ever add to its own list.

  The replacement is cast with `empty_values: []` because an empty one is the
  ordinary case — it is how a line is deleted — and the default cast would turn
  it into a NULL the column refuses. The pattern keeps the default, so a blank
  one is missing rather than a rule that matches the empty string everywhere.
  """
  def changeset(rewrite, attrs) do
    rewrite
    |> cast(attrs, [:pattern])
    |> cast(attrs, [:replacement], empty_values: [])
    |> validate_required([:pattern])
    |> validate_length(:pattern, max: @max_pattern)
    |> validate_length(:replacement, max: @max_replacement)
    |> validate_change(:pattern, fn :pattern, pattern ->
      case compile_pattern(pattern) do
        {:ok, _re} ->
          []

        {:error, reason} ->
          [pattern: {"is not a valid regular expression: %{reason}", reason: reason}]
      end
    end)
  end

  @doc """
  Compile `pattern` the way the rewrite runs it: `{:ok, compiled}` or
  `{:error, "missing closing parenthesis (at 1)"}`, PCRE's own words for the
  member who typed it.
  """
  def compile_pattern(pattern) when is_binary(pattern) do
    case :re.compile(pattern, @compile_opts) do
      {:ok, re} -> {:ok, re}
      {:error, {reason, at}} -> {:error, "#{reason} (at #{at})"}
    end
  end

  def compile_pattern(_pattern), do: {:error, "is empty"}
end
