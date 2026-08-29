defmodule Vutuv.WebPush.DispatcherTest do
  @moduledoc """
  Who gets woken while vutuv is closed, and what is said (issue #1729).

  It drives the real entry point, `dispatch/2`, which is fire and forget on
  `Vutuv.TaskSupervisor` — so every assertion waits (`assert_receive` /
  `refute_receive`) rather than reading an already-delivered message. That is
  what `async: false` buys: `Vutuv.DataCase` puts the sandbox in `{:shared,
  self()}` for a sync case, so the task sees the connection this test wrote its
  rows on.

  It is sync anyway, because it flips `:web_push_enabled`,
  `:web_push_req_options` and `:ssrf_resolver`, all global. `:web_push_enabled`
  is read by both push dispatchers, by `VutuvWeb.PushDeviceController` and by
  `VutuvWeb.ShellLive`.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers

  alias Vutuv.Repo
  alias Vutuv.WebPush.Dispatcher
  alias Vutuv.WebPush.Subscription
  alias Vutuv.WebPush.Subscriptions

  # Long enough that a slow machine is not mistaken for a push that never
  # happened, short enough that the four negative cases stay quick.
  @wait 500

  setup do
    put_config(:web_push_enabled, true)
    :ok
  end

  defp member(attrs \\ %{}) do
    user = insert(:user, Map.merge(%{browser_notifications?: true}, attrs))
    endpoint = "https://push.example.com/#{user.id}"

    {:ok, _subscription} =
      Subscriptions.subscribe(user.id, subscription_attrs(endpoint), "Safari on iPhone")

    user
  end

  test "pushes to every browser the member registered" do
    stub_push_service()
    user = member()

    Dispatcher.dispatch(user.id, %{kind: "follower", id: "follower:1"})

    assert_receive {:pushed, path}, @wait
    assert path == "/#{user.id}"
  end

  # The account switch is the master one: nobody who never asked for
  # notifications is pushed to, whatever a browser once registered. Switching
  # it off has to silence the phone too, or the switch means less than it says.
  test "says nothing to a member whose account switch is off" do
    stub_push_service()
    user = member(%{browser_notifications?: false})

    Dispatcher.dispatch(user.id, %{kind: "follower", id: "follower:1"})

    refute_receive {:pushed, _path}, @wait
  end

  test "says nothing on an installation whose operator switched push off" do
    stub_push_service()
    user = member()
    put_config(:web_push_enabled, false)

    Dispatcher.dispatch(user.id, %{kind: "follower", id: "follower:1"})

    refute_receive {:pushed, _path}, @wait
  end

  # A push service reporting the subscription gone is the only signal that a
  # browser has cleared its site data or the app was uninstalled. Acting on it
  # is what keeps the list clean without a sweeper — and without it, a dead row
  # is a failed request on every single notification, for ever.
  test "forgets a subscription the push service reports as gone" do
    stub_push_service(410)
    user = member()

    Dispatcher.dispatch(user.id, %{kind: "follower", id: "follower:1"})

    assert_receive {:pushed, _path}, @wait
    assert eventually(fn -> Subscriptions.for_user(user.id) == [] end)
  end

  test "keeps a subscription a push service merely failed on" do
    stub_push_service(500)
    user = member()

    Dispatcher.dispatch(user.id, %{kind: "follower", id: "follower:1"})

    assert_receive {:pushed, _path}, @wait
    assert [%Subscription{}] = Subscriptions.for_user(user.id)
  end

  # The payload is what a lock screen is drawn from, so this is where "a push
  # carries no content" is enforced. It names the kind and where the tap lands —
  # never the actor, never a word of what was written.
  test "the payload names the kind and the destination and nothing else" do
    test = self()

    put_config(:web_push_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, body})
        Plug.Conn.send_resp(conn, 201, "")
      end
    )

    put_config(:ssrf_resolver, fn _host, family ->
      if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:error, :nxdomain}
    end)

    user = member()

    Dispatcher.dispatch(user.id, %{
      kind: "like",
      id: "like:1",
      actor_name: "Anna Müller",
      text: "liked your post."
    })

    assert_receive {:body, body}, @wait
    # The body is aes128gcm, so nothing is legible in it either way; what this
    # asserts is that the plaintext never carried the words in the first
    # place — the encryption is not what is being relied on.
    refute body =~ "Anna"
    refute body =~ "liked your post"
  end

  describe "a direct message" do
    test "reaches the recipient's registered browsers" do
      stub_push_service()
      user = member()

      Dispatcher.dispatch_message(user.id)

      assert_receive {:pushed, _path}, @wait
    end

    # `Vutuv.Chat.recipient/2` answers a member id, `nil`, OR an
    # `%Organization{}` struct — and the struct is the one that actually occurs
    # for a page conversation, while `nil` is the shape everybody remembers.
    # Both must be a no-op rather than a `Repo.get(User, <not an id>)`; this is
    # the nullable-pair shape that has broken this code base five times (see
    # CLAUDE.md).
    test "is a no-op for a conversation whose far side is a page" do
      stub_push_service()

      assert Dispatcher.dispatch_message(nil) == :ok
      assert Dispatcher.dispatch_message(insert(:organization)) == :ok
      refute_receive {:pushed, _path}, @wait
    end
  end

  test "an unknown member is a no-op rather than a crash" do
    stub_push_service()

    assert Dispatcher.dispatch(Vutuv.UUIDv7.generate(), %{kind: "follower"}) == :ok
    refute_receive {:pushed, _path}, @wait
    assert Repo.aggregate(Subscription, :count) == 0
  end

  # The delete happens in the same task that sent, just after the push the test
  # already waited for, so give it a moment rather than racing it.
  defp eventually(check, attempts \\ 50) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, attempts - 1)
    end
  end
end
