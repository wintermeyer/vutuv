defmodule Vutuv.ExportTest do
  @moduledoc """
  The personal data export (`Vutuv.Export.build/1`). The follow/connect
  simplification means a "connection" is no longer a stored row but a *mutual
  follow*, and the connection-request email opt-in is gone, so the export must
  reflect that model rather than the dropped `connections` table.
  """
  use Vutuv.DataCase

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

  test "the profile keeps the live email opt-ins but not the dropped connection-request one" do
    profile = Export.build(insert(:activated_user)).profile

    assert Map.has_key?(profile, :email_on_endorsement)
    assert Map.has_key?(profile, :email_on_follower)
    refute Map.has_key?(profile, :email_on_connection_request)
  end

  test "education entries are included in the export" do
    user = insert(:activated_user)
    insert(:education, user: user, school: "Acme University", degree: "BSc")

    data = Export.build(user)

    assert [%{school: "Acme University", degree: "BSc"}] = data.educations
  end
end
