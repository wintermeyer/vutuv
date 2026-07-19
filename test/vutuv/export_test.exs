defmodule Vutuv.ExportTest do
  @moduledoc """
  The personal data export (`Vutuv.Export.build/1`). The follow/connect
  simplification means a "connection" is no longer a stored row but a *mutual
  follow*, and the connection-request email opt-in is gone, so the export must
  reflect that model rather than the dropped `connections` table.
  """
  use Vutuv.DataCase, async: true
  alias Vutuv.Export

  test "connections are derived from mutual follows, one-way follows excluded" do
    user = insert(:activated_user)
    mutual = insert(:activated_user)
    one_way = insert(:activated_user)

    # A mutual follow is vernetzt (a connection); a one-way follow is not.
    follow!(user, mutual)
    follow!(mutual, user)
    follow!(user, one_way)

    data = Export.build(user)

    assert [%{with: with_username, since: since}] = data.connections
    assert with_username == mutual.username
    assert %NaiveDateTime{} = since
    refute Enum.any?(data.connections, &(&1.with == one_way.username))
  end

  test "a member's blocks and private saves are included in the export (schema v3)" do
    user = insert(:activated_user)
    blocked = insert(:activated_user)
    saved_member = insert(:activated_user)

    Vutuv.Social.block_user(user, blocked)
    Vutuv.Social.bookmark_user(user, saved_member)

    data = Export.build(user)

    assert data.schema_version == 3
    assert Enum.any?(data.blocked_members, &(&1.member == blocked.username))
    assert Enum.any?(data.saved_members.bookmarked, &(&1.member == saved_member.username))
    # The keys exist even when empty, so the export shape stays stable.
    assert Map.has_key?(data.saved_organizations, :liked)
    assert Map.has_key?(data.saved_jobs, :bookmarked)
  end

  test "the profile keeps the live email opt-ins but not the dropped connection-request one" do
    profile = Export.build(insert(:activated_user)).profile

    assert Map.has_key?(profile, :email_on_endorsement)
    assert Map.has_key?(profile, :email_on_follower)
    refute Map.has_key?(profile, :email_on_connection_request)
  end

  test "education entries are included in the export, with their CV category (issue #849)" do
    user = insert(:activated_user)
    insert(:education, user: user, school: "Acme University", degree: "BSc", kind: "school")

    data = Export.build(user)

    assert [%{school: "Acme University", degree: "BSc", kind: "school"}] = data.educations
  end

  test "work experiences carry their CV category (issue #840)" do
    user = insert(:activated_user)
    insert(:work_experience, user: user, title: "Chair", kind: "volunteer")

    data = Export.build(user)

    assert [%{title: "Chair", kind: "volunteer"}] = data.work_experiences
  end
end
