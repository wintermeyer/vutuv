defmodule Vutuv.WelcomeTest do
  @moduledoc """
  The accounts the welcome window's last step offers, and the step list that
  follows from them (`Vutuv.Welcome`).

  **`async: false`, and it has to be**: every test here sets
  `:welcome_suggestions`, which `Application.put_env/3` writes globally and the
  SQL sandbox does not roll back — `config/test.exs` clears the key for the rest
  of the suite so nothing else can send a real WebFinger request, and a test
  running beside this one would see whatever list it had installed at that
  moment. `Vutuv.Fediverse` is the only other reader.

  Two things are worth guarding here. **Nothing on another server is offered to
  a member who has no fediverse** — neither one who left the sign-up checkbox
  alone nor anyone on an installation with federation switched off — because a
  `Follow` from them could never leave, and a suggestion that quietly does
  nothing is worse than no suggestion. And **the step count follows the
  resolved list, not the configured one**, so "Schritt 1 von 3" is never
  promised to somebody who will only get two.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.MastodonHelpers, only: [remote_account: 1]

  alias Vutuv.Social
  alias Vutuv.Welcome

  @remote "@tagesschau@ard.social"

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp suggest(addresses), do: put_config(:welcome_suggestions, %{"de" => addresses})

  # A member of this installation, with the fediverse switch as the sign-up form
  # leaves it unless the visitor unticks it.
  defp federating_user, do: insert(:activated_user, fediverse_followers?: true)

  describe "an account on another server" do
    test "is offered to a member who takes part in the fediverse" do
      suggest([@remote])

      assert [suggestion] = Welcome.suggested_accounts(federating_user(), "de")
      assert suggestion.address == @remote
      assert suggestion.handle == @remote
      # Never seen here, so the handle is all we know — and it still reads as a
      # name rather than as a machine address.
      assert Welcome.label(suggestion) == "tagesschau"
    end

    test "is not offered to a member who has no fediverse" do
      suggest([@remote])

      assert Welcome.suggested_accounts(insert(:activated_user), "de") == []
    end

    test "is not offered while this installation has federation off" do
      suggest([@remote])
      put_config(:fediverse_enabled, false)

      assert Welcome.suggested_accounts(federating_user(), "de") == []
    end

    test "carries the name and picture of one we already hold" do
      account =
        remote_account(
          actor_uri: "https://ard.social/users/tagesschau",
          handle: "tagesschau",
          name: "tagesschau"
        )

      suggest([@remote])

      assert [suggestion] = Welcome.suggested_accounts(federating_user(), "de")
      assert suggestion.remote_account.id == account.id
      assert Welcome.label(suggestion) == "tagesschau"
    end
  end

  describe "a member on this installation" do
    test "is offered by their bare handle, whatever the member's fediverse says" do
      member = insert(:activated_user, username: "wintermeyer")
      suggest(["@wintermeyer"])

      # The viewer takes no part in the fediverse: a vutuv follow needs none.
      assert [suggestion] = Welcome.suggested_accounts(insert(:activated_user), "de")
      assert suggestion.user.id == member.id
      assert suggestion.handle == "@wintermeyer"
    end

    test "drops off the list where nobody is called that" do
      suggest(["@nobody-here"])

      assert Welcome.suggested_accounts(federating_user(), "de") == []
    end
  end

  describe "which steps a member gets" do
    test "two without suggestions, three with" do
      suggest([])
      assert Welcome.steps(federating_user(), "de") == [:location, :job]

      insert(:activated_user, username: "wintermeyer")
      suggest(["@wintermeyer"])
      assert Welcome.steps(federating_user(), "de") == [:location, :job, :accounts]
    end

    # The count the member reads is the count they get: a configured list that
    # resolves to nothing must not promise a third step.
    test "two when the configured list resolves to nothing" do
      suggest([@remote])

      assert Welcome.steps(insert(:activated_user), "de") == [:location, :job]
    end

    test "two for a locale with no list of its own" do
      suggest([@remote])

      assert Welcome.steps(federating_user(), "en") == [:location, :job]
    end

    test "the last step is where Fertig sits" do
      assert Welcome.next_step([:location, :job], :location) == :job
      assert Welcome.next_step([:location, :job], :job) == :done
      assert Welcome.next_step([:location, :job, :accounts], :job) == :accounts
    end

    # A stored step this member no longer has (a locale that lost its list
    # between two requests) starts them over rather than rendering nothing.
    test "a stored step that no longer exists falls back to the first" do
      assert Welcome.current_step([:location, :job], :accounts) == :location
      assert Welcome.current_step([:location, :job], nil) == :location
      assert Welcome.current_step([:location, :job], :job) == :job
    end
  end

  describe "following what was ticked" do
    test "a local member is followed for real" do
      member = insert(:activated_user, username: "wintermeyer")
      suggest(["@wintermeyer"])
      user = insert(:activated_user)

      assert Welcome.follow_suggested(user, ["@wintermeyer"]) == 1
      assert Social.user_follows_user?(user.id, member.id)
    end

    # The form hands us strings, so the configured list is the allow-list: a
    # hand-built POST must not make this server send a Follow of its choosing.
    test "an address nobody configured is not followed" do
      insert(:activated_user, username: "somebody")
      suggest(["@wintermeyer"])
      user = insert(:activated_user)

      assert Welcome.follow_suggested(user, ["@somebody"]) == 0
      refute Social.follows_anyone?(user)
    end

    test "nothing ticked follows nobody" do
      suggest(["@wintermeyer"])
      user = insert(:activated_user)

      assert Welcome.follow_suggested(user, []) == 0
      assert Welcome.follow_suggested(user, [""]) == 0
      refute Social.follows_anyone?(user)
    end
  end
end
