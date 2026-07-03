defmodule Vutuv.Newsletters.BroadcastResumerTest do
  @moduledoc """
  The sweep that restarts newsletter broadcasts whose send task died mid-loop
  (a crash on one recipient, or a blue/green deploy stopping the slot). The
  GenServer itself is config-gated off in tests (`:resume_stuck_broadcasts`,
  like every periodic job); the sweep body is tested directly.
  """
  use Vutuv.DataCase

  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.{BroadcastResumer, Newsletter, NewsletterDelivery}

  test "sweep/0 resumes a stuck broadcast to completion and leaves others alone" do
    admin = insert(:activated_user, admin?: true)
    ann = insert(:activated_user, first_name: "Ann")
    insert(:email, user: ann, value: "ann@example.com")

    {:ok, stuck} =
      Newsletters.create_newsletter(%{"subject" => "S", "body" => "B"}, admin)

    {:ok, fresh_draft} =
      Newsletters.create_newsletter(%{"subject" => "S2", "body" => "B2"}, admin)

    old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -600, :second)

    Repo.update_all(from(n in Newsletter, where: n.id == ^stuck.id),
      set: [status: "sending", updated_at: old]
    )

    BroadcastResumer.sweep()

    finished = Newsletters.get_newsletter!(stuck.id)
    assert finished.status == "sent"
    assert finished.recipient_count == 1
    assert [%{to: [{_, "ann@example.com"}]}] = flush_emails()
    assert [%NewsletterDelivery{status: "sent"}] = Newsletters.list_deliveries(finished)

    assert Newsletters.get_newsletter!(fresh_draft.id).status == "draft"
  end

  test "sweep/0 is a no-op when nothing is stuck" do
    BroadcastResumer.sweep()
    assert flush_emails() == []
  end
end
